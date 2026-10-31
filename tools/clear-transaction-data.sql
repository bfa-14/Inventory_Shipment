/*
    CLEAR TRANSACTION DATA - empties every transaction table and keeps security, master data and settings.

    Kept (not touched):
      security.*        users, roles, permissions, refresh tokens, login audit
      masterdata.*      branches, warehouses, currencies, rates, families, brands, units, parties, ports,
                        price lists, unit prices and their history, ...
      configuration.*   settings and their change log
      inventory.Items, ItemUnits, ItemFiles      the item master (images and files included)
      inventory.DocumentTypes, StockReasons      lookups
      purchase.ChargeTypes, ApprovalSettings, OrderApprovers, GoodsReceiptSwitch
      messaging.EmailSettings

    Also done:
      - Identity columns restart at their seed, so the next document gets Id 1 again.
      - inventory.DocumentSequences is emptied, so document numbers restart (the procedures recreate a
        sequence row on first use).
      - The item running costs (AverageCost, LastCost, FobCost, LastPurchaseAtUtc, LastSupplierId) are reset,
        because they were built from the stock movements being deleted.

    TRUNCATE is not allowed on a table another foreign key points at, even an empty or disabled one, so
    those tables are cleared with DELETE (foreign keys switched off for the run) and reseeded.

    Run it against the right database. Take a backup first. @DryRun = 1 does everything inside the
    transaction, prints the counts, then rolls back.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DryRun BIT = 1;          -- 1 = test and roll back, 0 = clear for real
DECLARE @ExpectedDatabase SYSNAME = N'Inventory_Shipment';

DECLARE @CurrentDatabase SYSNAME = DB_NAME();
IF @CurrentDatabase <> @ExpectedDatabase
BEGIN
    RAISERROR(N'Connected to [%s], expected [%s]. Nothing was changed.', 16, 1, @CurrentDatabase, @ExpectedDatabase);
    RETURN;
END;

DECLARE @Clear TABLE (ObjectId INT PRIMARY KEY, Name NVARCHAR(300) NOT NULL);

INSERT INTO @Clear (ObjectId, Name)
SELECT OBJECT_ID(v.Name), v.Name
FROM (VALUES
    -- inventory
    (N'inventory.CostAdjustments'), (N'inventory.DocumentSequences'), (N'inventory.ItemImportLogs'),
    (N'inventory.ShortageDocumentAudit'), (N'inventory.ShortageDocumentLines'), (N'inventory.ShortageDocuments'),
    (N'inventory.StockDocumentAudit'), (N'inventory.StockDocumentFiles'), (N'inventory.StockDocumentLines'),
    (N'inventory.StockDocuments'), (N'inventory.StockMovements'),
    -- logistics
    (N'logistics.ContainerAttachments'), (N'logistics.ContainerAudit'), (N'logistics.ContainerChargeAllocations'),
    (N'logistics.ContainerCharges'), (N'logistics.ContainerEvents'), (N'logistics.ContainerFiles'),
    (N'logistics.ContainerInvoices'), (N'logistics.ContainerLines'), (N'logistics.Containers'),
    (N'logistics.Files'), (N'logistics.MovementContainers'), (N'logistics.Movements'),
    -- purchase
    (N'purchase.GoodsReceiptAudit'), (N'purchase.GoodsReceiptCostChanges'), (N'purchase.GoodsReceiptFiles'),
    (N'purchase.GoodsReceiptInvoiceMatches'), (N'purchase.GoodsReceiptLines'), (N'purchase.GoodsReceipts'),
    (N'purchase.LandedCostAdjustmentLines'), (N'purchase.LandedCostAdjustments'),
    (N'purchase.PaymentAllocationContainers'), (N'purchase.PaymentAllocations'), (N'purchase.PaymentAudit'),
    (N'purchase.PaymentFiles'), (N'purchase.PaymentLines'), (N'purchase.Payments'),
    (N'purchase.PurchaseChargeAllocations'), (N'purchase.PurchaseCharges'), (N'purchase.PurchaseDocumentAudit'),
    (N'purchase.PurchaseDocumentFiles'), (N'purchase.PurchaseDocumentLines'), (N'purchase.PurchaseDocuments'),
    (N'purchase.PurchaseOrderApprovalEvents'), (N'purchase.PurchaseOrderApprovals'),
    -- sales
    (N'sales.InvoiceImportLogs'), (N'sales.OutOfStockSaleAudit'), (N'sales.ReceiptAllocations'),
    (N'sales.ReceiptAudit'), (N'sales.ReceiptFiles'), (N'sales.ReceiptLines'), (N'sales.Receipts'),
    (N'sales.SalesDocumentAudit'), (N'sales.SalesDocumentFiles'), (N'sales.SalesDocumentLines'),
    (N'sales.SalesDocuments'),
    -- messaging: the e-mails already sent or queued (approval links included)
    (N'messaging.EmailOutbox')
) AS v (Name)
WHERE OBJECT_ID(v.Name, N'U') IS NOT NULL;   -- an older database may not have every table yet

/* A KEPT TABLE MUST NOT POINT AT A CLEARED ONE - its rows would be left referring to nothing. Stop
   before changing anything if a newer script added such a link. */
IF EXISTS (SELECT 1
           FROM sys.foreign_keys fk
           JOIN @Clear c ON c.ObjectId = fk.referenced_object_id
           WHERE fk.parent_object_id NOT IN (SELECT ObjectId FROM @Clear))
BEGIN
    SELECT OBJECT_SCHEMA_NAME(fk.parent_object_id) + N'.' + OBJECT_NAME(fk.parent_object_id) AS KeptTable,
           c.Name AS ClearedTable, fk.name AS ForeignKey
    FROM sys.foreign_keys fk
    JOIN @Clear c ON c.ObjectId = fk.referenced_object_id
    WHERE fk.parent_object_id NOT IN (SELECT ObjectId FROM @Clear);
    RAISERROR(N'A kept table references a table to be cleared (listed above). Nothing was changed.', 16, 1);
    RETURN;
END;

DECLARE @Sql NVARCHAR(MAX);

BEGIN TRANSACTION;

-- 1. Switch off the foreign keys of the cleared tables (every key pointing at them is among these).
SELECT @Sql = STRING_AGG(CAST(N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N'.'
              + QUOTENAME(OBJECT_NAME(fk.parent_object_id)) + N' NOCHECK CONSTRAINT ' + QUOTENAME(fk.name)
              AS NVARCHAR(MAX)), N';' + CHAR(10))
FROM sys.foreign_keys fk
JOIN @Clear c ON c.ObjectId = fk.parent_object_id;
IF @Sql IS NOT NULL EXEC sys.sp_executesql @Sql;

-- 2. TRUNCATE what nothing points at, DELETE the rest and restart its identity at the seed.
DECLARE @Statements TABLE (Statement NVARCHAR(MAX) NOT NULL);

INSERT INTO @Statements (Statement)
SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.foreign_keys fk WHERE fk.referenced_object_id = c.ObjectId)
            THEN N'DELETE FROM ' + q.Name
                 + CASE WHEN ic.last_value IS NOT NULL   -- reseeding a never-used table would start it at 0
                        THEN N'; DBCC CHECKIDENT (''' + REPLACE(q.Name, N'''', N'''''') + N''', RESEED, '
                             + CAST(CAST(ic.seed_value AS BIGINT) - CAST(ic.increment_value AS BIGINT) AS NVARCHAR(30))
                             + N') WITH NO_INFOMSGS'
                        ELSE N'' END
            ELSE N'TRUNCATE TABLE ' + q.Name END
FROM @Clear c
CROSS APPLY (SELECT QUOTENAME(OBJECT_SCHEMA_NAME(c.ObjectId)) + N'.' + QUOTENAME(OBJECT_NAME(c.ObjectId)) AS Name) q
LEFT JOIN sys.identity_columns ic ON ic.object_id = c.ObjectId;

SELECT @Sql = STRING_AGG(Statement, N';' + CHAR(10)) FROM @Statements;
EXEC sys.sp_executesql @Sql;

-- 3. Switch the foreign keys back on WITH CHECK, so SQL Server keeps trusting them.
SELECT @Sql = STRING_AGG(CAST(N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N'.'
              + QUOTENAME(OBJECT_NAME(fk.parent_object_id)) + N' WITH CHECK CHECK CONSTRAINT ' + QUOTENAME(fk.name)
              AS NVARCHAR(MAX)), N';' + CHAR(10))
FROM sys.foreign_keys fk
JOIN @Clear c ON c.ObjectId = fk.parent_object_id;
IF @Sql IS NOT NULL EXEC sys.sp_executesql @Sql;

-- 4. The item running costs came from the movements and goods receipts just deleted.
UPDATE inventory.Items
SET AverageCost = 0, LastCost = NULL, FobCost = NULL, LastPurchaseAtUtc = NULL, LastSupplierId = NULL;

-- 5. Report: every cleared table should now show 0 rows.
SELECT c.Name AS ClearedTable,
       (SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = c.ObjectId AND p.index_id IN (0, 1)) AS RowsNow
FROM @Clear c
ORDER BY c.Name;

IF @DryRun = 1
BEGIN
    ROLLBACK TRANSACTION;
    PRINT N'DRY RUN - everything was rolled back. Set @DryRun = 0 to clear for real.';
END
ELSE
BEGIN
    COMMIT TRANSACTION;
    PRINT N'Transaction data cleared.';
END;
