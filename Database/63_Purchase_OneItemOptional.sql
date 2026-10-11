SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 63: ONE ITEM PER SUPPLIER INVOICE BECOMES OPTIONAL

   Script 45 (prompt 37) made every supplier invoice (PINV) hold one item. The business owner made it a choice: the
   rule stays the default, a setting switches it off, and every creation of invoices can choose for itself.

   Rule
     - SETTING Purchase.OneItemPerInvoice (configuration.SettingDefinitions of script 39, group General, bool, default
       true = as before, public: the web reads it as the default of its switches). Shown on Configuration > Settings.
     - EVERY SUPPLIER INVOICE HAS ITS OWN MODE, purchase.PurchaseDocuments.OneItemOnly (BIT NULL, PINV only), set when
       it is created and kept: 1 = it holds one item (the 65029 refusal of script 45 applies to it), 0 = it may hold
       several items. NULL = an invoice created before this script: it follows the setting as it is NOW.
       Effective mode = COALESCE(OneItemOnly, setting).
     - usp_PurchaseDocument_Save: new optional @OneItemOnly, used when a PINV is INSERTED (NULL = the setting) and
       stored; an update keeps the stored mode. 65029 only when the invoice's effective mode is 1.
     - usp_PurchaseDocument_Post: the same effective check.
     - usp_PurchaseDocument_CreateFromContainers and _CreateFromSource (PO -> PINV): new optional @OnePerItem (NULL =
       the setting). 1 = one draft per item as before (each OneItemOnly = 1); 0 = ONE draft holding every selected line,
       OneItemOnly = 0, created the same way (header, totals, container links, receipt mode). The same rows are
       returned (one per invoice created, + ItemCount at the end) and @NewId is the first: existing callers keep working.
     - usp_PurchaseDocument_SplitByItem: still any DRAFT PINV holding several items (a 0 one too); every invoice it
       leaves, the original included, gets OneItemOnly = 1.
     - usp_PurchaseDocument_Get returns OneItemOnly (effective; 0 on orders and returns). The list already gives
       ItemCount (script 45): a multi-item invoice says how many items it holds. usp_PurchaseDocument_Search adds
       OneItemOnly (effective; NULL on orders and returns), so the list tells an invoice of several items from a draft
       of one item that holds several (saved before that rule, refused by Post until it is split).
     - fn_PurchaseInvoice_ContainerState (script 51): its rule 3 (split a draft of several items before it takes
       containers) only for an invoice whose mode is one item. A draft of several items with mode 0 is linked / given
       containers item by item, as a posted invoice of several items already was.
     - The Excel import of supplier invoices (API) follows the setting, or the caller's choice.

   Objects
     configuration.SettingDefinitions: Purchase.OneItemPerInvoice (new row)
     purchase.PurchaseDocuments.OneItemOnly (new column)
     purchase.fn_PurchaseInvoice_Row (re-created from its current body, script 45: + ItemCount)
     purchase.usp_PurchaseDocument_Save / _CreateFromContainers / _CreateFromSource / _SplitByItem (re-created from
       their current bodies, script 45)
     purchase.usp_PurchaseDocument_Post (re-created from its current body, script 48)
     purchase.usp_PurchaseDocument_Get / _Search (re-created from their current bodies, script 47)
     purchase.fn_PurchaseInvoice_ContainerState (re-created from its current body, script 51)

   Errors: unchanged (65029 a supplier invoice of one item holds one item).

   Requires scripts 39, 45, 47, 48 and 51. Idempotent, additive: re-applied at every API start-up through Schema.sql.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'configuration.SettingDefinitions', N'U') IS NULL
   OR OBJECT_ID(N'configuration.fn_SettingBool', N'FN') IS NULL
   OR OBJECT_ID(N'purchase.fn_PurchaseInvoice_Row', N'IF') IS NULL
   OR OBJECT_ID(N'purchase.usp_PurchaseDocument_SplitByItem', N'P') IS NULL
   OR OBJECT_ID(N'purchase.fn_InvoiceSettlement', N'IF') IS NULL
   OR OBJECT_ID(N'purchase.fn_PurchaseInvoice_ContainerState', N'IF') IS NULL
BEGIN
    RAISERROR ('Run scripts 39, 45, 47, 48 and 51 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. The setting */

-- The definition belongs to the application: it is written again on every run (text, type, default), the value an
-- administrator chose (configuration.SettingValues) is never touched.
IF EXISTS (SELECT 1 FROM configuration.SettingDefinitions WHERE SettingKey = N'Purchase.OneItemPerInvoice')
    UPDATE configuration.SettingDefinitions
    SET GroupName = N'General', Label = N'One item per supplier invoice',
        Description = N'On: a new supplier invoice holds one item - creating invoices from an order, its containers or an Excel file makes one invoice per item. Off: one invoice can hold several items. The Create Invoice dialogs can still choose for each creation, and an invoice keeps the choice it was created with.',
        ValueType = N'bool', DefaultValue = N'true', MinValue = NULL, MaxValue = NULL, IsPublic = 1, SortOrder = 20
    WHERE SettingKey = N'Purchase.OneItemPerInvoice';
ELSE
    INSERT INTO configuration.SettingDefinitions (SettingKey, GroupName, Label, Description, ValueType, DefaultValue, IsPublic, SortOrder)
    VALUES (N'Purchase.OneItemPerInvoice', N'General', N'One item per supplier invoice',
            N'On: a new supplier invoice holds one item - creating invoices from an order, its containers or an Excel file makes one invoice per item. Off: one invoice can hold several items. The Create Invoice dialogs can still choose for each creation, and an invoice keeps the choice it was created with.',
            N'bool', N'true', 1, 20);
GO

/* ================================================================== 2. The mode of every supplier invoice */

-- Before any procedure below reads it. NULL on orders and returns, and on the invoices created before this script
-- (they follow the setting).
IF COL_LENGTH(N'purchase.PurchaseDocuments', N'OneItemOnly') IS NULL
    ALTER TABLE purchase.PurchaseDocuments ADD OneItemOnly BIT NULL;   -- PINV: 1 one item (65029), 0 several items, NULL = the setting
GO

/* ================================================================== 3. The row of a created invoice: + how many items */

-- Re-created (63) from the body of script 45: + ItemCount (more than 1 for an invoice of several items).
CREATE OR ALTER FUNCTION purchase.fn_PurchaseInvoice_Row (@Id INT)
RETURNS TABLE
AS
RETURN
    SELECT d.Id, f.ItemId, i.ItemCode, i.ItemName, LineCount = x.Lines, QuantityBase = x.Qty, d.TotalAmount, d.RowVersion,
           ItemCount = x.Items   -- (63)
    FROM purchase.PurchaseDocuments d
    CROSS APPLY (SELECT Lines = COUNT(*), Qty = ISNULL(SUM(QuantityBase), 0), Items = COUNT(DISTINCT ItemId)
                 FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id) x
    OUTER APPLY (SELECT TOP (1) ItemId FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id ORDER BY LineNumber) f
    LEFT  JOIN inventory.Items i ON i.Id = f.ItemId
    WHERE d.Id = @Id;
GO

/* ================================================================== 4. Save: the mode of a new invoice, the check by mode */

-- Re-created (63) from the body of script 45: + @OneItemOnly; 65029 only for an invoice whose mode is one item.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Save
    @Id                  INT            = NULL,
    @DocumentTypeCode    NVARCHAR(20),
    @DocumentDate        DATE,
    @ExpectedDate        DATE           = NULL,
    @BranchId            INT,
    @WarehouseId         INT = NULL,
    @SupplierId          INT,
    @CurrencyId          INT            = NULL,
    @RateType            TINYINT        = 1,
    @ExchangeRate        DECIMAL(18,6)  = NULL,
    @SupplierReference   NVARCHAR(100)  = NULL,
    @Notes               NVARCHAR(1000) = NULL,
    @Lines               purchase.tvp_PurchaseDocumentLine READONLY,
    @MaxDiscountPercent  DECIMAL(9,4)   = 100,
    @SourceDocumentId    INT            = NULL,
    @RowVersion          BINARY(8)      = NULL,
    @UserId              INT            = NULL,
    @ReceiptMode         TINYINT        = NULL,    -- NULL = unchanged (1 on creation)
    @ExporterReference   NVARCHAR(50)   = NULL,
    @CommercialInvoiceNo NVARCHAR(50)   = NULL,
    @LineContainers      purchase.tvp_LineContainer READONLY,   -- invoice from containers: the container line of every line
    @NewId               INT OUTPUT,
    @OneItemOnly         BIT            = NULL     -- (63) a NEW supplier invoice: 1 one item, 0 several; NULL = the setting. Kept on update.
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* The warehouse lives on the LINES. The header keeps one so that document lists, filters,
       reports and exports still have a warehouse to show; when the caller does not send one it is
       taken from the first line. */
    IF @WarehouseId IS NULL
        SELECT TOP (1) @WarehouseId = WarehouseId FROM @Lines ORDER BY LineNumber;

    SET @SupplierReference = NULLIF(LTRIM(RTRIM(@SupplierReference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @ExporterReference = NULLIF(LTRIM(RTRIM(@ExporterReference)), N'');
    SET @CommercialInvoiceNo = NULLIF(LTRIM(RTRIM(@CommercialInvoiceNo)), N'');
    IF @ReceiptMode IS NOT NULL AND @ReceiptMode NOT IN (1, 2) THROW 65000, 'Receipt mode must be 1 (on posting) or 2 (on container offload).', 1;
    IF @ReceiptMode = 2 AND @DocumentTypeCode <> N'PINV' THROW 65000, 'Only purchase invoices can be received on container offload.', 1;

    DECLARE @TypeId INT, @Direction SMALLINT, @Cur INT, @Rate DECIMAL(18,6);
    EXEC purchase.usp_PurchaseDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId, @SupplierId,
         @CurrencyId, @RateType, @ExchangeRate, @MaxDiscountPercent, @SourceDocumentId, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @Cur OUTPUT, @Rate OUTPUT;

    -- (63) ONE ITEM OR SEVERAL IS THE INVOICE'S OWN MODE: chosen when it is created (@OneItemOnly, NULL = the setting
    --      Purchase.OneItemPerInvoice) and kept by every later save. An invoice saved before script 63 has none: it
    --      follows the setting as it is now. Orders and returns have no mode.
    DECLARE @OneItem BIT = NULL;
    IF @DocumentTypeCode = N'PINV'
        SET @OneItem = COALESCE(CASE WHEN @Id IS NULL THEN @OneItemOnly
                                     ELSE (SELECT OneItemOnly FROM purchase.PurchaseDocuments WHERE Id = @Id) END,
                                configuration.fn_SettingBool(N'Purchase.OneItemPerInvoice'));

    -- (45) A supplier invoice holds ONE item: any number of lines, all of the same item. (63) When its mode says so.
    IF @OneItem = 1 AND (SELECT COUNT(DISTINCT ItemId) FROM @Lines) > 1
    BEGIN
        DECLARE @ItemCount INT = (SELECT COUNT(DISTINCT ItemId) FROM @Lines), @ItemCodes NVARCHAR(400);
        SELECT @ItemCodes = STRING_AGG(x.ItemCode, N', ') WITHIN GROUP (ORDER BY x.FirstLine)
        FROM (SELECT TOP (5) i.ItemCode, FirstLine = MIN(l.LineNumber)
              FROM @Lines l INNER JOIN inventory.Items i ON i.Id = l.ItemId
              GROUP BY l.ItemId, i.ItemCode
              ORDER BY MIN(l.LineNumber)) x;
        SET @ItemCodes = N'A supplier invoice holds one item. This one has ' + CAST(@ItemCount AS NVARCHAR(10)) + N': ' + @ItemCodes
                         + CASE WHEN @ItemCount > 5 THEN N'...' ELSE N'.' END + N' Create one invoice per item, or use Split by item.';
        THROW 65029, @ItemCodes, 1;
    END

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status <> 1 THROW 65005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 65000, 'The document type cannot be changed.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND ISNULL(SourceDocumentId, 0) <> ISNULL(@SourceDocumentId, 0))
            THROW 65000, 'The source document cannot be changed.', 1;
        -- (43) A container is unlinked from the Containers card of the invoice (usp_PurchaseInvoice_UnlinkContainer),
        --      never by saving the invoice without the lines that are on it.
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines pl
                   WHERE pl.DocumentId = @Id AND pl.ContainerLineId IS NOT NULL
                     AND NOT EXISTS (SELECT 1 FROM @LineContainers x WHERE x.ContainerLineId = pl.ContainerLineId))
        BEGIN
            IF @ReceiptMode = 1 THROW 65026, 'Unlink the containers before switching off Shipped in containers.', 1;
            THROW 65019, 'This invoice is linked to containers: keep their lines, or unlink a container from the Containers card of the invoice.', 1;
        END
    END

    -- Lines linked to containers (all of them, or (43) only some: the rest is linked later) point to a container line of
    -- the same order line and item, within what is loaded and not yet invoiced elsewhere. A linked line forces receipt
    -- mode 2 ("shipped in containers").
    IF EXISTS (SELECT 1 FROM @LineContainers)
    BEGIN
        IF @DocumentTypeCode <> N'PINV' THROW 65019, 'Only purchase invoices can be linked to containers.', 1;
        IF @SourceDocumentId IS NULL THROW 65019, 'An invoice from containers must refer to its purchase order.', 1;
        IF EXISTS (SELECT 1 FROM @LineContainers x WHERE NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.LineNumber = x.LineNumber))
            THROW 65019, 'A container line is given for a line that does not exist.', 1;
        IF @Id IS NOT NULL AND EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id)
            THROW 65020, 'This invoice has its own charges. Remove them: the charges of an import are entered on its containers.', 1;

        DECLARE @CtMsg NVARCHAR(400);
        SELECT TOP (1) @CtMsg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN cl.Id IS NULL THEN N'the container line no longer exists.'
                 WHEN c.Status IN (6, 7, 8) THEN N'container ' + c.ContainerRef + N' is already offloaded, closed or cancelled.'
                 WHEN cl.PurchaseOrderId <> @SourceDocumentId THEN N'the container line belongs to another purchase order.'
                 WHEN cl.ItemId <> l.ItemId THEN N'the item differs from the container line.'
                 ELSE N'the order line differs from the container line.' END
        FROM @Lines l
        INNER JOIN @LineContainers x          ON x.LineNumber = l.LineNumber
        LEFT  JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
        LEFT  JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        WHERE cl.Id IS NULL OR c.Status IN (6, 7, 8) OR cl.PurchaseOrderId <> @SourceDocumentId
           OR cl.ItemId <> l.ItemId OR ISNULL(l.SourceLineId, 0) <> cl.PoLineId
        ORDER BY l.LineNumber;
        IF @CtMsg IS NOT NULL THROW 65019, @CtMsg, 1;

        SELECT TOP (1) @CtMsg = N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                + CAST(q.Here AS NVARCHAR(20)) + N' invoiced here + ' + CAST(ISNULL(o.Other, 0) AS NVARCHAR(20))
                                + N' in other invoices, but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' are loaded.'
        FROM (SELECT x.ContainerLineId, Here = SUM(l.Quantity * iu.PackingFormula)
              FROM @Lines l
              INNER JOIN @LineContainers x      ON x.LineNumber = l.LineNumber
              INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
              GROUP BY x.ContainerLineId) q
        INNER JOIN logistics.ContainerLines cl ON cl.Id = q.ContainerLineId
        INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        INNER JOIN inventory.Items i           ON i.Id = cl.ItemId
        OUTER APPLY (SELECT Other = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3 AND (@Id IS NULL OR pd.Id <> @Id)) o
        WHERE q.Here + ISNULL(o.Other, 0) > cl.QuantityBase
        ORDER BY c.ContainerRef, cl.LineNumber;
        IF @CtMsg IS NOT NULL THROW 65019, @CtMsg, 1;

        IF @ReceiptMode = 1 THROW 65026, 'Unlink the containers before switching off Shipped in containers.', 1;
        SET @ReceiptMode = 2;
    END

    -- (43) "Shipped in containers" (receipt mode 2) is chosen on a purchase invoice: NULL = unchanged (1 on creation).
    DECLARE @EffectiveMode TINYINT = CASE WHEN @DocumentTypeCode <> N'PINV' THEN 1
                                          ELSE COALESCE(@ReceiptMode, (SELECT ReceiptMode FROM purchase.PurchaseDocuments WHERE Id = @Id), 1) END;
    DECLARE @ModeMsg NVARCHAR(400);
    IF @EffectiveMode = 2
    BEGIN
        -- the goods enter the stock at the offload of the containers they are linked to: lines of the order only
        IF @SourceDocumentId IS NULL THROW 65000, 'Only an invoice created from a purchase order can be shipped in containers.', 1;
        SELECT TOP (1) @ModeMsg = N'Line ' + CAST(LineNumber AS NVARCHAR(10)) + N': only lines of the purchase order can be shipped in containers.'
        FROM @Lines WHERE SourceLineId IS NULL ORDER BY LineNumber;
        IF @ModeMsg IS NOT NULL THROW 65000, @ModeMsg, 1;
    END
    ELSE IF @DocumentTypeCode = N'PINV' AND @SourceDocumentId IS NOT NULL
    BEGIN
        -- received on posting: what the containers of the order hold plus what is invoiced outside containers cannot
        -- exceed the order line, or the same goods would be received twice
        SELECT TOP (1) @ModeMsg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): the containers of the order hold '
                                  + CAST(ct.Qty AS NVARCHAR(20)) + N' of the ' + CAST(pol.QuantityBase AS NVARCHAR(20))
                                  + N' ordered. Keep Shipped in containers on and link the invoice to them.'
        FROM (SELECT x.SourceLineId, Qty = SUM(x.Quantity * iu.PackingFormula), LineNumber = MIN(x.LineNumber)
              FROM @Lines x INNER JOIN inventory.ItemUnits iu ON iu.Id = x.ItemUnitId
              WHERE x.SourceLineId IS NOT NULL GROUP BY x.SourceLineId) l
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.SourceLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        CROSS APPLY (SELECT Qty = ISNULL(SUM(cl.QuantityBase), 0) FROM logistics.ContainerLines cl
                     INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                     WHERE cl.PoLineId = pol.Id AND c.Status <> 8) ct
        OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                     INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                     WHERE x.SourceLineId = pol.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2
                       AND (@Id IS NULL OR xd.Id <> @Id)) dir
        WHERE ct.Qty > 0 AND l.Qty + ISNULL(dir.Qty, 0) + ct.Qty > pol.QuantityBase
        ORDER BY l.LineNumber;
        IF @ModeMsg IS NOT NULL THROW 65026, @ModeMsg, 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO purchase.PurchaseDocuments (DocumentTypeId, DocumentNumber, DocumentDate, ExpectedDate, BranchId, WarehouseId, SupplierId,
                                                    CurrencyId, RateType, ExchangeRate, SupplierReference, Notes, Status, SourceDocumentId,
                                                    ReceiptMode, ExporterReference, CommercialInvoiceNo, CreatedBy, OneItemOnly)
            VALUES (@TypeId, @Number, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId, @SupplierId,
                    @Cur, @RateType, @Rate, @SupplierReference, @Notes, 1, @SourceDocumentId,
                    ISNULL(@ReceiptMode, 1), @ExporterReference, @CommercialInvoiceNo, @UserId,
                    @OneItem);   -- (63) the mode of a new supplier invoice, stored once (NULL on orders and returns)
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)')
                        + ISNULL(N' from ' + (SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @SourceDocumentId), N''), @UserId);
        END
        ELSE
        BEGIN
            UPDATE purchase.PurchaseDocuments
            SET DocumentDate = @DocumentDate, ExpectedDate = @ExpectedDate, BranchId = @BranchId, WarehouseId = @WarehouseId,
                SupplierId = @SupplierId, CurrencyId = @Cur, RateType = @RateType, ExchangeRate = @Rate,
                SupplierReference = @SupplierReference, Notes = @Notes,
                ReceiptMode = ISNULL(@ReceiptMode, ReceiptMode),
                ExporterReference = @ExporterReference, CommercialInvoiceNo = @CommercialInvoiceNo,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            -- Lines are replaced: manual charge allocations pointing at the old lines are dropped (the charges stay).
            DELETE a FROM purchase.PurchaseChargeAllocations a
            INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId
            WHERE c.DocumentKind = N'PINV' AND c.DocumentId = @Id;
            DELETE FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;

            INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        INSERT INTO purchase.PurchaseDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                                    UnitPrice, DiscountPercent, UnitCostBase, FobCostBase, ImportRowNumber, Notes, SourceLineId)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, l.WarehouseId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
               ISNULL(l.UnitPrice, ROUND(ISNULL(i.LastCost, 0) * iu.PackingFormula * @Rate, 4)),
               ISNULL(l.DiscountPercent, 0),
               CASE WHEN @DocumentTypeCode = N'PRET' THEN COALESCE(scl.LandedCostBase, src.UnitCostBase) END,   -- returns carry the LANDED cost (the container's for imports)
               CASE WHEN @DocumentTypeCode = N'PRET' THEN COALESCE(scl.FobCostBase, src.FobCostBase) END,
               l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N''), l.SourceLineId
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        LEFT  JOIN purchase.PurchaseDocumentLines src ON src.Id = l.SourceLineId
        LEFT  JOIN logistics.ContainerLines scl       ON scl.Id = src.ContainerLineId;

        UPDATE pl SET ContainerLineId = x.ContainerLineId
        FROM purchase.PurchaseDocumentLines pl
        INNER JOIN @LineContainers x ON x.LineNumber = pl.LineNumber
        WHERE pl.DocumentId = @Id;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / @Rate, 2), TotalLandedCostBase = ROUND(x.Amt / @Rate, 2) + d.TotalChargesBase
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        -- the value basis of the container charges follows the invoice prices
        IF EXISTS (SELECT 1 FROM @LineContainers)
        BEGIN
            DECLARE @Cid INT;
            DECLARE cts CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT cl.ContainerId FROM @LineContainers x INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId;
            OPEN cts;
            FETCH NEXT FROM cts INTO @Cid;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
                FETCH NEXT FROM cts INTO @Cid;
            END
            CLOSE cts;
            DEALLOCATE cts;
        END

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 5. Post: the same check */

-- Re-created (63) from the body of script 48 (approval of 42, line warehouses of any branch kept): 65029 by mode.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Post
    @Id         INT,
    @RowVersion   BINARY(8) = NULL,
    @UserId       INT       = NULL,
    @FromApproval BIT       = 0      -- 1 = called by the approval
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE,
                @BranchId INT, @SupplierId INT, @Rate DECIMAL(18,6), @SourceId INT, @ReceiptMode TINYINT,
                @OneItemOnly BIT;

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @SupplierId = d.SupplierId, @Rate = d.ExchangeRate,
               @SourceId = d.SourceDocumentId, @ReceiptMode = d.ReceiptMode,
               @OneItemOnly = d.OneItemOnly
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode = N'PO' AND ISNULL(@FromApproval, 0) = 1 AND @Status <> 5
            THROW 65010, 'Only a purchase order waiting for approval can be approved.', 1;
        IF (@TypeCode <> N'PO' OR ISNULL(@FromApproval, 0) = 0) AND @Status <> 1
            THROW 65010, 'Only draft documents can be posted.', 1;

        DECLARE @PostedWithoutApproval BIT = CASE WHEN @TypeCode = N'PO' AND ISNULL(@FromApproval, 0) = 0 THEN 1 ELSE 0 END;
        IF @PostedWithoutApproval = 1 AND purchase.fn_PurchaseOrder_NeedsApproval(@Id) = 1
            THROW 65013, 'This order needs approval: send it for approval.', 1;

        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id)
            THROW 65009, 'The document has no lines. Add at least one item before posting.', 1;

        -- (45) A supplier invoice holds ONE item: a draft saved with several before script 45 is split first.
        -- (63) Only when its mode is one item: its own, or the setting when it has none (saved before script 63).
        IF @TypeCode = N'PINV' AND COALESCE(@OneItemOnly, configuration.fn_SettingBool(N'Purchase.OneItemPerInvoice')) = 1
           AND (SELECT COUNT(DISTINCT ItemId) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) > 1
        BEGIN
            DECLARE @ItemCount INT = (SELECT COUNT(DISTINCT ItemId) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id),
                    @ItemCodes NVARCHAR(400);
            SELECT @ItemCodes = STRING_AGG(x.ItemCode, N', ') WITHIN GROUP (ORDER BY x.FirstLine)
            FROM (SELECT TOP (5) i.ItemCode, FirstLine = MIN(l.LineNumber)
                  FROM purchase.PurchaseDocumentLines l INNER JOIN inventory.Items i ON i.Id = l.ItemId
                  WHERE l.DocumentId = @Id
                  GROUP BY l.ItemId, i.ItemCode
                  ORDER BY MIN(l.LineNumber)) x;
            SET @ItemCodes = N'A supplier invoice holds one item. This one has ' + CAST(@ItemCount AS NVARCHAR(10)) + N': ' + @ItemCodes
                         + CASE WHEN @ItemCount > 5 THEN N'...' ELSE N'.' END + N' Create one invoice per item, or use Split by item.';
            THROW 65029, @ItemCodes, 1;
        END
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsActive = 1)
            THROW 65008, 'The supplier is inactive.', 1;

        -- Imports: the goods are received by the container, not by this posting.
        DECLARE @ReceiveNow BIT = CASE WHEN @TypeCode = N'PINV' AND @ReceiptMode = 2 THEN 0 ELSE 1 END;

        DECLARE @FromContainers BIT = CASE WHEN @TypeCode = N'PINV' AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines
                                                                                WHERE DocumentId = @Id AND ContainerLineId IS NOT NULL) THEN 1 ELSE 0 END;
        -- (43) Shipped in containers: an imported invoice, linked to its containers now or later. Lines not in a container
        --      yet are allowed: they enter the stock at the offload of the containers they are linked to afterwards.
        IF @TypeCode = N'PINV' AND @ReceiptMode = 2
        BEGIN
            IF NULLIF(LTRIM(RTRIM((SELECT ExporterReference FROM purchase.PurchaseDocuments WHERE Id = @Id))), N'') IS NULL
                THROW 65018, 'The exporter reference is required on an imported invoice. Enter it before posting.', 1;
            IF EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id)
                THROW 65020, 'This invoice has its own charges. Remove them: the charges of an import are entered on its containers.', 1;
        END

        IF @FromContainers = 1
        BEGIN

            DECLARE @CtMsg NVARCHAR(400);
            SELECT TOP (1) @CtMsg = N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                    + CASE WHEN c.Status IN (6, 7, 8) THEN N'the container is already offloaded, closed or cancelled.'
                                           ELSE CAST(q.Here AS NVARCHAR(20)) + N' invoiced here + ' + CAST(ISNULL(o.Posted, 0) AS NVARCHAR(20))
                                                + N' in posted invoices, but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' are loaded.' END
            FROM (SELECT ContainerLineId, Here = SUM(QuantityBase) FROM purchase.PurchaseDocumentLines
                  WHERE DocumentId = @Id GROUP BY ContainerLineId) q
            INNER JOIN logistics.ContainerLines cl ON cl.Id = q.ContainerLineId
            INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
            INNER JOIN inventory.Items i           ON i.Id = cl.ItemId
            OUTER APPLY (SELECT Posted = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                         INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                         WHERE pil.ContainerLineId = cl.Id AND pd.Status IN (2, 4) AND pd.Id <> @Id) o
            WHERE c.Status IN (6, 7, 8) OR q.Here + ISNULL(o.Posted, 0) > cl.QuantityBase
            ORDER BY c.ContainerRef, cl.LineNumber;
            IF @CtMsg IS NOT NULL THROW 65019, @CtMsg, 1;
        END

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.' END
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 65000, @Msg, 1;

        IF @SourceId IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 2)
                THROW 65011, 'The source document is no longer open (cancelled or closed).', 1;

            IF @TypeCode = N'PINV'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units invoiced but only ' + CAST(s.QuantityBase - s.ReceivedQuantityBase AS NVARCHAR(20)) + N' remain on the order line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReceivedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
            IF @TypeCode = N'PRET'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units returned but only ' + CAST(s.QuantityBase - s.ReturnedQuantityBase AS NVARCHAR(20)) + N' can still be returned from the invoice line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReturnedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
        END

        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        IF @TypeCode = N'PINV'
        BEGIN
            -- FOB per base unit, then charges allocated over the lines, then landed cost per base unit.
            EXEC purchase.usp_PurchaseCharges_Allocate N'PINV', @Id, @Id;

            UPDATE l
            SET FobCostBase = (l.LineTotal / @Rate) / l.QuantityBase,
                AllocatedChargesBase = ISNULL(a.Total, 0),
                UnitCostBase = ((l.LineTotal / @Rate) + ISNULL(a.Total, 0)) / l.QuantityBase
            FROM purchase.PurchaseDocumentLines l
            OUTER APPLY (SELECT SUM(x.AmountBase) AS Total
                         FROM purchase.PurchaseChargeAllocations x
                         INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                         WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'PINV' AND c.DocumentId = @Id AND c.IncludeInLandedCost = 1) a
            WHERE l.DocumentId = @Id;

            UPDATE d
            SET TotalChargesBase = ISNULL(x.Charges, 0), TotalLandedCostBase = d.TotalAmountBase + ISNULL(x.Charges, 0)
            FROM purchase.PurchaseDocuments d
            CROSS APPLY (SELECT SUM(AllocatedChargesBase) AS Charges FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
            WHERE d.Id = @Id;
        END
        ELSE IF @TypeCode = N'PRET'
            UPDATE l SET UnitCostBase = ISNULL(l.UnitCostBase, ISNULL(inventory.fn_AverageCost(l.ItemId), 0))
            FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;

        IF @Direction = 1 AND @ReceiveNow = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, ISNULL(l.UnitCostBase, 0), l.FobCostBase FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId, 1;
        END

        IF @Direction <> 0 AND @ReceiveNow = 1
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            -- (48) the branch of the line's warehouse, which need not be the document's branch
            SELECT @MovementDate, l.ItemId, l.WarehouseId, w.BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Purchase', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM purchase.PurchaseDocumentLines l
            INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
            WHERE l.DocumentId = @Id;

            IF @Direction = 1
                UPDATE purchase.PurchaseDocumentLines SET ReceivedQuantityBase = QuantityBase WHERE DocumentId = @Id;
        END

        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @SourceId AND ReceivedQuantityBase < QuantityBase)
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 4, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, CloseReason = N'Fully received' WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Closed', N'Fully received by ' + @Number, @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        UPDATE purchase.PurchaseDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id);
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 AND @ReceiveNow = 1 THEN N' written to the stock ledger'
                                       WHEN @ReceiveNow = 0 THEN N'; stock will be received when the container is offloaded'
                                       WHEN @PostedWithoutApproval = 1 THEN N' (approval not needed)'
                                       ELSE N' (order approved)' END
                                + CASE WHEN @TypeCode = N'PINV' THEN N'; landed charges ' + CAST((SELECT TotalChargesBase FROM purchase.PurchaseDocuments WHERE Id = @Id) AS NVARCHAR(30)) ELSE N'' END, @UserId);

        -- A purchase order posted without approval: the user who posts it is recorded as approver, as an approval does.
        IF @PostedWithoutApproval = 1
        BEGIN
            UPDATE purchase.PurchaseDocuments SET ApprovedAtUtc = SYSUTCDATETIME(), ApprovedBy = @UserId WHERE Id = @Id;

            DECLARE @RequireApproval BIT, @ApprovalLimit DECIMAL(19, 4);
            SELECT @RequireApproval = RequireApproval, @ApprovalLimit = ApprovalLimitBase FROM purchase.ApprovalSettings WHERE Id = 1;
            INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, UserId, Note)
            VALUES (@Id, 7, @UserId,
                    CASE WHEN @RequireApproval = 0 THEN N'Approval not required'
                         ELSE N'Under the approval limit of ' + FORMAT(@ApprovalLimit, N'N2', N'en-US')
                              + ISNULL(N' ' + (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies
                                               WHERE IsBaseCurrency = 1 AND IsActive = 1), N'') END);
        END

        -- containers of an import: the invoice is known now (value basis of the charges, history)
        IF @FromContainers = 1
        BEGIN
            DECLARE @Cid INT;
            DECLARE cts CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT cl.ContainerId FROM purchase.PurchaseDocumentLines l
                INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                WHERE l.DocumentId = @Id;
            OPEN cts;
            FETCH NEXT FROM cts INTO @Cid;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
                INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
                VALUES (@Cid, N'Updated', N'Purchase invoice ' + @Number + N' posted', @UserId);
                FETCH NEXT FROM cts INTO @Cid;
            END
            CLOSE cts;
            DEALLOCATE cts;
        END

        COMMIT TRANSACTION;
        IF ISNULL(@FromApproval, 0) = 0 SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 6. CreateFromContainers: one invoice per item, or one */

-- Re-created (63) from the body of script 45: + @OnePerItem.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_CreateFromContainers
    @PurchaseOrderId INT,
    @Selection       logistics.tvp_ContainerLineQty READONLY,
    @DocumentDate    DATE = NULL,
    @UserId          INT  = NULL,
    @NewId           INT OUTPUT,                      -- (45) the FIRST invoice created
    @ExporterReference   NVARCHAR(50) = NULL,         -- (45) copied to every invoice created
    @CommercialInvoiceNo NVARCHAR(50) = NULL,         -- (45) copied to every invoice created
    @OnePerItem          BIT          = NULL          -- (63) 1 one invoice per item, 0 one invoice of every item; NULL = the setting
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @TypeCode NVARCHAR(20), @Status TINYINT, @BranchId INT, @WarehouseId INT, @SupplierId INT, @CurrencyId INT,
            @RateType TINYINT, @SupplierRef NVARCHAR(100);
    SELECT @TypeCode = dt.Code, @Status = d.Status, @BranchId = d.BranchId, @WarehouseId = d.WarehouseId, @SupplierId = d.SupplierId,
           @CurrencyId = d.CurrencyId, @RateType = d.RateType, @SupplierRef = d.SupplierReference
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE d.Id = @PurchaseOrderId;

    IF @TypeCode IS NULL THROW 65006, 'Purchase order not found.', 1;
    IF @TypeCode <> N'PO' THROW 65011, 'Invoices from containers are created for a purchase order.', 1;
    IF @Status <> 2 THROW 65011, 'The purchase order must be approved and still open.', 1;

    DECLARE @Pick TABLE (ContainerLineId INT PRIMARY KEY, QuantityBase INT);
    IF EXISTS (SELECT 1 FROM @Selection)
        INSERT INTO @Pick (ContainerLineId, QuantityBase) SELECT ContainerLineId, QuantityBase FROM @Selection;
    ELSE
        INSERT INTO @Pick (ContainerLineId, QuantityBase)
        SELECT cl.Id, cl.QuantityBase - ISNULL(q.Qty, 0)
        FROM logistics.ContainerLines cl
        INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
        OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
        WHERE cl.PurchaseOrderId = @PurchaseOrderId AND c.Status NOT IN (6, 7, 8) AND cl.QuantityBase - ISNULL(q.Qty, 0) > 0;

    IF NOT EXISTS (SELECT 1 FROM @Pick) THROW 65019, 'Nothing is left to invoice on the containers of this order.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        CASE WHEN cl.Id IS NULL THEN N'A selected container line no longer exists.'
             WHEN cl.PurchaseOrderId <> @PurchaseOrderId THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' belongs to another purchase order.'
             WHEN c.Status IN (6, 7, 8) THEN N'Container ' + c.ContainerRef + N' is already offloaded, closed or cancelled.'
             WHEN p.QuantityBase <= 0 THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': the quantity must be greater than zero.'
             ELSE N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': ' + CAST(p.QuantityBase AS NVARCHAR(20))
                  + N' selected but only ' + CAST(cl.QuantityBase - ISNULL(q.Qty, 0) AS NVARCHAR(20)) + N' are loaded and not yet invoiced.' END
    FROM @Pick p
    LEFT JOIN logistics.ContainerLines cl ON cl.Id = p.ContainerLineId
    LEFT JOIN logistics.Containers c      ON c.Id = cl.ContainerId
    OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
    WHERE cl.Id IS NULL OR cl.PurchaseOrderId <> @PurchaseOrderId OR c.Status IN (6, 7, 8) OR p.QuantityBase <= 0
       OR p.QuantityBase > cl.QuantityBase - ISNULL(q.Qty, 0)
    ORDER BY c.ContainerRef, cl.LineNumber;
    IF @Msg IS NOT NULL THROW 65019, @Msg, 1;

    -- the order line must still allow it (posted invoices + drafts)
    SELECT TOP (1) @Msg = N'Order line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): ' + CAST(x.Qty AS NVARCHAR(20))
                          + N' selected but only ' + CAST(pol.QuantityBase - pol.ReceivedQuantityBase - ISNULL(dr.Qty, 0) AS NVARCHAR(20))
                          + N' remain to invoice (the rest is in posted or draft invoices).'
    FROM (SELECT cl.PoLineId, Qty = SUM(p.QuantityBase) FROM @Pick p
          INNER JOIN logistics.ContainerLines cl ON cl.Id = p.ContainerLineId GROUP BY cl.PoLineId) x
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = x.PoLineId
    INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
    OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                 WHERE pil.SourceLineId = pol.Id AND pd.Status = 1) dr
    WHERE x.Qty > pol.QuantityBase - pol.ReceivedQuantityBase - ISNULL(dr.Qty, 0)
    ORDER BY pol.LineNumber;
    IF @Msg IS NOT NULL THROW 65011, @Msg, 1;

    DECLARE @Rows TABLE (LineNumber INT PRIMARY KEY, ContainerLineId INT, PoLineId INT, QuantityBase INT);
    INSERT INTO @Rows (LineNumber, ContainerLineId, PoLineId, QuantityBase)
    SELECT ROW_NUMBER() OVER (ORDER BY c.ContainerRef, cl.LineNumber), cl.Id, cl.PoLineId, p.QuantityBase
    FROM @Pick p
    INNER JOIN logistics.ContainerLines cl ON cl.Id = p.ContainerLineId
    INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId;

    DECLARE @Lines purchase.tvp_PurchaseDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
    SELECT r.LineNumber, pol.ItemId, u.ItemUnitId, @WarehouseId, pol.ExpiryDate, u.Quantity, u.UnitPrice, pol.DiscountPercent, NULL,
           LEFT(N'Container ' + c.ContainerRef + ISNULL(N' / ' + c.ContainerNo, N''), 300), pol.Id
    FROM @Rows r
    INNER JOIN logistics.ContainerLines cl        ON cl.Id = r.ContainerLineId
    INNER JOIN logistics.Containers c             ON c.Id = cl.ContainerId
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = r.PoLineId
    CROSS APPLY (SELECT ItemUnitId = CASE WHEN r.QuantityBase % pol.PackingFormula = 0 THEN pol.ItemUnitId
                                          ELSE (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = pol.ItemId AND IsBaseUnit = 1) END,
                        Quantity   = CASE WHEN r.QuantityBase % pol.PackingFormula = 0 THEN r.QuantityBase / pol.PackingFormula ELSE r.QuantityBase END,
                        UnitPrice  = CASE WHEN r.QuantityBase % pol.PackingFormula = 0 THEN pol.UnitPrice ELSE ROUND(pol.UnitPrice / pol.PackingFormula, 4) END) u;

    -- (45) ONE INVOICE PER ITEM: the lines are split by item, in the order of each item's first line, and every invoice
    --      is created exactly as one was before (usp_PurchaseDocument_Save: header, lines, totals, audit), all or nothing.
    -- (63) ...UNLESS @OnePerItem = 0 (NULL = the setting Purchase.OneItemPerInvoice): then ONE invoice holds every line,
    --      in the same order, created the same way; its mode allows several items (OneItemOnly = 0). With 1 every
    --      invoice is of one item (OneItemOnly = 1), as before.
    SET @OnePerItem = COALESCE(@OnePerItem, configuration.fn_SettingBool(N'Purchase.OneItemPerInvoice'));
    DECLARE @Items TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ItemId INT NOT NULL UNIQUE);
    INSERT INTO @Items (ItemId) SELECT ItemId FROM @Lines GROUP BY ItemId ORDER BY MIN(LineNumber);

    DECLARE @Created TABLE (Seq INT PRIMARY KEY, InvoiceId INT NOT NULL);
    DECLARE @Part purchase.tvp_PurchaseDocumentLine, @PartContainers purchase.tvp_LineContainer;
    DECLARE @Seq INT = 1, @Last INT = CASE WHEN @OnePerItem = 1 THEN (SELECT MAX(Seq) FROM @Items) ELSE 1 END, @Item INT, @InvoiceId INT;

    BEGIN TRY
        BEGIN TRANSACTION;
        WHILE @Seq <= @Last
        BEGIN
            SET @Item = (SELECT ItemId FROM @Items WHERE Seq = @Seq);

            DELETE FROM @Part;
            INSERT INTO @Part (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
            SELECT ROW_NUMBER() OVER (ORDER BY LineNumber), ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent,
                   ImportRowNumber, Notes, SourceLineId
            FROM @Lines WHERE ItemId = @Item OR @OnePerItem = 0;

            DELETE FROM @PartContainers;
            INSERT INTO @PartContainers (LineNumber, ContainerLineId)
            SELECT ROW_NUMBER() OVER (ORDER BY r.LineNumber), r.ContainerLineId
            FROM @Rows r INNER JOIN @Lines l ON l.LineNumber = r.LineNumber
            WHERE l.ItemId = @Item OR @OnePerItem = 0;

            SET @InvoiceId = NULL;
            EXEC purchase.usp_PurchaseDocument_Save
                 @Id = NULL, @DocumentTypeCode = N'PINV', @DocumentDate = @DocumentDate, @ExpectedDate = NULL,
                 @BranchId = @BranchId, @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @CurrencyId = @CurrencyId,
                 @RateType = @RateType, @ExchangeRate = NULL, @SupplierReference = @SupplierRef, @Notes = NULL,
                 @Lines = @Part, @MaxDiscountPercent = 100, @SourceDocumentId = @PurchaseOrderId, @RowVersion = NULL, @UserId = @UserId,
                 @ReceiptMode = 2, @ExporterReference = @ExporterReference, @CommercialInvoiceNo = @CommercialInvoiceNo,
                 @LineContainers = @PartContainers, @NewId = @InvoiceId OUTPUT, @OneItemOnly = @OnePerItem;
            INSERT INTO @Created (Seq, InvoiceId) VALUES (@Seq, @InvoiceId);

            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            SELECT DISTINCT cl.ContainerId, N'Updated',
                   N'Draft purchase invoice ' + ISNULL((SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId),
                                                       N'#' + CAST(@InvoiceId AS NVARCHAR(10)))
                   + N' created from the container', @UserId
            FROM @PartContainers x INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId;

            SET @Seq += 1;
        END
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    -- the first invoice, as before: the callers that read @NewId keep working
    SET @NewId = (SELECT InvoiceId FROM @Created WHERE Seq = 1);

    SELECT r.Id, r.ItemId, r.ItemCode, r.ItemName, r.LineCount, r.QuantityBase, r.TotalAmount, r.RowVersion, r.ItemCount
    FROM @Created c CROSS APPLY purchase.fn_PurchaseInvoice_Row(c.InvoiceId) r
    ORDER BY c.Seq;
END
GO

/* ================================================================== 7. CreateFromSource: one invoice per item, or one (PO -> PINV) */

-- Re-created (63) from the body of script 45: + @OnePerItem (PO -> PINV); PINV -> PRET unchanged.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_CreateFromSource
    @SourceId       INT,
    @TargetTypeCode NVARCHAR(20),        -- PINV (from PO) | PRET (from PINV)
    @DocumentDate   DATE = NULL,         -- default today
    @Selection      purchase.tvp_SourceLineSelection READONLY,   -- lines + base quantities to take; empty = everything still available
    @UserId         INT  = NULL,
    @NewId          INT OUTPUT,                       -- (45) PO -> PINV: the FIRST invoice created
    @ExporterReference   NVARCHAR(50) = NULL,         -- (45) PO -> PINV: copied to every invoice created
    @CommercialInvoiceNo NVARCHAR(50) = NULL,         -- (45) PO -> PINV: copied to every invoice created
    @OnePerItem          BIT          = NULL          -- (63) PO -> PINV: 1 one invoice per item, 0 one invoice of every item; NULL = the setting
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @SrcType NVARCHAR(20), @Status TINYINT, @BranchId INT, @WarehouseId INT, @SupplierId INT, @CurrencyId INT, @RateType TINYINT, @SupplierRef NVARCHAR(100);
    SELECT @SrcType = dt.Code, @Status = d.Status, @BranchId = d.BranchId, @WarehouseId = d.WarehouseId, @SupplierId = d.SupplierId,
           @CurrencyId = d.CurrencyId, @RateType = d.RateType, @SupplierRef = d.SupplierReference
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceId;

    IF @SrcType IS NULL THROW 65006, 'Source document not found.', 1;
    IF @Status <> 2 THROW 65011, 'The source document must be approved / posted and still open.', 1;
    IF NOT ((@TargetTypeCode = N'PINV' AND @SrcType = N'PO') OR (@TargetTypeCode = N'PRET' AND @SrcType = N'PINV'))
        THROW 65011, 'Purchase orders become purchase invoices; purchase invoices become purchase returns.', 1;
    -- (43) An order with containers gives an invoice "shipped in containers" (receipt mode 2): its lines are linked to the
    --      containers afterwards (usp_PurchaseInvoice_LinkContainers). It used to be refused (65021).
    DECLARE @ReceiptMode TINYINT =
        CASE WHEN @SrcType = N'PO' AND EXISTS (SELECT 1 FROM logistics.ContainerLines cl INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                                               WHERE cl.PurchaseOrderId = @SourceId AND c.Status <> 8)
             THEN 2 END;

    -- Several drafts may be created from the same document: what is already in another DRAFT of the target type is not
    -- offered again. A selection takes only the given lines / base quantities.
    DECLARE @HasSelection BIT = CASE WHEN EXISTS (SELECT 1 FROM @Selection) THEN 1 ELSE 0 END;
    IF @HasSelection = 1
    BEGIN
        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg = CASE WHEN l.Id IS NULL THEN N'A selected line does not belong to the source document.'
                                   WHEN sel.QuantityBase <= 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the quantity must be greater than zero.'
                                   ELSE N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + CAST(sel.QuantityBase AS NVARCHAR(20))
                                        + N' base units selected but only ' + CAST(av.Available AS NVARCHAR(20))
                                        + N' are still available (the rest is in posted or draft documents).' END
        FROM @Selection sel
        LEFT JOIN purchase.PurchaseDocumentLines l ON l.Id = sel.SourceLineId AND l.DocumentId = @SourceId
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 INNER JOIN inventory.DocumentTypes xt ON xt.Id = xd.DocumentTypeId
                 WHERE x.SourceLineId = l.Id AND xd.Status = 1 AND xt.Code = @TargetTypeCode) dr
    CROSS APPLY (SELECT Available = CASE WHEN @SrcType = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                         ELSE l.QuantityBase - l.ReturnedQuantityBase END - ISNULL(dr.Qty, 0)) av
        WHERE l.Id IS NULL OR sel.QuantityBase <= 0 OR sel.QuantityBase > av.Available
        ORDER BY sel.SourceLineId;
        IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
    END

    -- Remaining quantity per line; when it is not a whole number of the line's unit, the new line uses the BASE unit
    -- (price converted per base unit) so nothing is over-received or over-returned.
    DECLARE @Lines purchase.tvp_PurchaseDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
    SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber), l.ItemId, c.ItemUnitId, l.WarehouseId, l.ExpiryDate,
           c.Quantity, c.UnitPrice, l.DiscountPercent, NULL, l.Notes, l.Id
    FROM purchase.PurchaseDocumentLines l
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 INNER JOIN inventory.DocumentTypes xt ON xt.Id = xd.DocumentTypeId
                 WHERE x.SourceLineId = l.Id AND xd.Status = 1 AND xt.Code = @TargetTypeCode) dr
    CROSS APPLY (SELECT Available = CASE WHEN @SrcType = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                         ELSE l.QuantityBase - l.ReturnedQuantityBase END - ISNULL(dr.Qty, 0)) av
    LEFT JOIN @Selection sel ON sel.SourceLineId = l.Id
    CROSS APPLY (SELECT Remaining = CASE WHEN @HasSelection = 1 THEN ISNULL(sel.QuantityBase, 0) ELSE av.Available END) r
    CROSS APPLY (SELECT ItemUnitId = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.ItemUnitId
                                          ELSE (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = l.ItemId AND IsBaseUnit = 1) END,
                        Quantity   = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN r.Remaining / l.PackingFormula ELSE r.Remaining END,
                        UnitPrice  = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.UnitPrice ELSE ROUND(l.UnitPrice / l.PackingFormula, 4) END) c
    WHERE l.DocumentId = @SourceId AND r.Remaining > 0;

    IF NOT EXISTS (SELECT 1 FROM @Lines) THROW 65011, 'Nothing is left on the source document: everything is already in posted or draft documents.', 1;

    -- A return (any pair but PO -> PINV): one document, as before.
    IF @TargetTypeCode <> N'PINV'
    BEGIN
        EXEC purchase.usp_PurchaseDocument_Save
             @Id = NULL, @DocumentTypeCode = @TargetTypeCode, @DocumentDate = @DocumentDate, @ExpectedDate = NULL,
             @BranchId = @BranchId, @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @CurrencyId = @CurrencyId,
             @RateType = @RateType, @ExchangeRate = NULL, @SupplierReference = @SupplierRef, @Notes = NULL,
             @Lines = @Lines, @MaxDiscountPercent = 100, @SourceDocumentId = @SourceId, @RowVersion = NULL, @UserId = @UserId,
             @ReceiptMode = @ReceiptMode, @NewId = @NewId OUTPUT;
        RETURN;
    END

    -- (45) ONE INVOICE PER ITEM: the lines are split by item, in the order of each item's first line, and every invoice
    --      is created exactly as one was before (usp_PurchaseDocument_Save: header, lines, totals, audit), all or nothing.
    -- (63) ...UNLESS @OnePerItem = 0 (NULL = the setting Purchase.OneItemPerInvoice): then ONE invoice holds every line,
    --      in the same order, created the same way; its mode allows several items (OneItemOnly = 0). With 1 every
    --      invoice is of one item (OneItemOnly = 1), as before.
    SET @OnePerItem = COALESCE(@OnePerItem, configuration.fn_SettingBool(N'Purchase.OneItemPerInvoice'));
    DECLARE @Items TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ItemId INT NOT NULL UNIQUE);
    INSERT INTO @Items (ItemId) SELECT ItemId FROM @Lines GROUP BY ItemId ORDER BY MIN(LineNumber);

    DECLARE @Created TABLE (Seq INT PRIMARY KEY, InvoiceId INT NOT NULL);
    DECLARE @Part purchase.tvp_PurchaseDocumentLine;
    DECLARE @Seq INT = 1, @Last INT = CASE WHEN @OnePerItem = 1 THEN (SELECT MAX(Seq) FROM @Items) ELSE 1 END, @Item INT, @InvoiceId INT;

    BEGIN TRY
        BEGIN TRANSACTION;
        WHILE @Seq <= @Last
        BEGIN
            SET @Item = (SELECT ItemId FROM @Items WHERE Seq = @Seq);

            DELETE FROM @Part;
            INSERT INTO @Part (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
            SELECT ROW_NUMBER() OVER (ORDER BY LineNumber), ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent,
                   ImportRowNumber, Notes, SourceLineId
            FROM @Lines WHERE ItemId = @Item OR @OnePerItem = 0;

            SET @InvoiceId = NULL;
            EXEC purchase.usp_PurchaseDocument_Save
                 @Id = NULL, @DocumentTypeCode = N'PINV', @DocumentDate = @DocumentDate, @ExpectedDate = NULL,
                 @BranchId = @BranchId, @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @CurrencyId = @CurrencyId,
                 @RateType = @RateType, @ExchangeRate = NULL, @SupplierReference = @SupplierRef, @Notes = NULL,
                 @Lines = @Part, @MaxDiscountPercent = 100, @SourceDocumentId = @SourceId, @RowVersion = NULL, @UserId = @UserId,
                 @ReceiptMode = @ReceiptMode, @ExporterReference = @ExporterReference, @CommercialInvoiceNo = @CommercialInvoiceNo,
                 @NewId = @InvoiceId OUTPUT, @OneItemOnly = @OnePerItem;
            INSERT INTO @Created (Seq, InvoiceId) VALUES (@Seq, @InvoiceId);

            SET @Seq += 1;
        END
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    -- the first invoice, as before: the callers that read @NewId keep working
    SET @NewId = (SELECT InvoiceId FROM @Created WHERE Seq = 1);

    SELECT r.Id, r.ItemId, r.ItemCode, r.ItemName, r.LineCount, r.QuantityBase, r.TotalAmount, r.RowVersion, r.ItemCount
    FROM @Created c CROSS APPLY purchase.fn_PurchaseInvoice_Row(c.InvoiceId) r
    ORDER BY c.Seq;
END
GO

/* ================================================================== 8. Split a draft invoice by item */

-- Re-created (63) from the body of script 45: allowed on any draft purchase invoice holding several items, whatever its
-- mode; every invoice it leaves (the original included) is of one item from then on (OneItemOnly = 1).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_SplitByItem
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Created TABLE (Seq INT PRIMARY KEY, InvoiceId INT NOT NULL, ItemId INT NOT NULL);

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @TypeId INT, @BranchId INT;
        SELECT @Status = d.Status, @TypeCode = dt.Code, @TypeId = d.DocumentTypeId, @BranchId = d.BranchId
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PINV' OR @Status <> 1 THROW 65010, 'Only a draft purchase invoice can be split by item.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF (SELECT COUNT(DISTINCT ItemId) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) <= 1
            THROW 65000, 'This invoice already holds one item.', 1;

        -- the items in the order of their first line: the first one stays
        DECLARE @Items TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ItemId INT NOT NULL UNIQUE);
        INSERT INTO @Items (ItemId)
        SELECT ItemId FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId ORDER BY MIN(LineNumber), MIN(Id);
        INSERT INTO @Created (Seq, InvoiceId, ItemId) SELECT 1, @Id, ItemId FROM @Items WHERE Seq = 1;

        DELETE a
        FROM purchase.PurchaseChargeAllocations a
        INNER JOIN purchase.PurchaseCharges c       ON c.Id = a.ChargeId AND c.DocumentKind = N'PINV' AND c.DocumentId = @Id
        INNER JOIN purchase.PurchaseDocumentLines l ON l.Id = a.PurchaseLineId
        WHERE l.ItemId <> (SELECT ItemId FROM @Items WHERE Seq = 1);

        DECLARE @Seq INT = 2, @Last INT = (SELECT MAX(Seq) FROM @Items), @Item INT, @NewId INT, @Number NVARCHAR(30);
        WHILE @Seq <= @Last
        BEGIN
            SET @Item = (SELECT ItemId FROM @Items WHERE Seq = @Seq);

            -- numbered now only when the type numbers its drafts (a purchase invoice is numbered on posting)
            SET @Number = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO purchase.PurchaseDocuments (DocumentTypeId, DocumentNumber, DocumentDate, ExpectedDate, BranchId, WarehouseId, SupplierId,
                                                    CurrencyId, RateType, ExchangeRate, SupplierReference, Notes, Status, SourceDocumentId,
                                                    SourceShortageId, ReceiptMode, ExporterReference, CommercialInvoiceNo,
                                                    ApprovalRequestedAtUtc, ApprovalRequestedBy, ApprovedAtUtc, ApprovedBy, ApprovalChannel,
                                                    RejectedAtUtc, RejectedBy, RejectReason, CreatedBy)
            SELECT DocumentTypeId, @Number, DocumentDate, ExpectedDate, BranchId, WarehouseId, SupplierId,
                   CurrencyId, RateType, ExchangeRate, SupplierReference, Notes, 1, SourceDocumentId,
                   SourceShortageId, ReceiptMode, ExporterReference, CommercialInvoiceNo,
                   ApprovalRequestedAtUtc, ApprovalRequestedBy, ApprovedAtUtc, ApprovedBy, ApprovalChannel,
                   RejectedAtUtc, RejectedBy, RejectReason, @UserId
            FROM purchase.PurchaseDocuments
            WHERE Id = @Id;
            SET @NewId = SCOPE_IDENTITY();

            -- the lines of the item move, every column kept, numbered from 1
            UPDATE l SET DocumentId = @NewId, LineNumber = x.Seq
            FROM purchase.PurchaseDocumentLines l
            INNER JOIN (SELECT Id, Seq = ROW_NUMBER() OVER (ORDER BY LineNumber, Id)
                        FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND ItemId = @Item) x ON x.Id = l.Id;

            INSERT INTO @Created (Seq, InvoiceId, ItemId) VALUES (@Seq, @NewId, @Item);
            SET @Seq += 1;
        END

        -- what stays on the original, numbered from 1
        UPDATE l SET LineNumber = x.Seq
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN (SELECT Id, Seq = ROW_NUMBER() OVER (ORDER BY LineNumber, Id)
                    FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x ON x.Id = l.Id
        WHERE l.LineNumber <> x.Seq;

        -- the totals of every invoice, as usp_PurchaseDocument_Save computes them
        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / d.ExchangeRate, 2), TotalLandedCostBase = ROUND(x.Amt / d.ExchangeRate, 2) + d.TotalChargesBase,
            OneItemOnly = 1,      -- (63) split by item: each invoice holds one item from now on, the original too
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM purchase.PurchaseDocuments d
        INNER JOIN @Created c ON c.InvoiceId = d.Id
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id) x;

        DECLARE @Into NVARCHAR(MAX) =
            (SELECT STRING_AGG(N'draft #' + CAST(c.InvoiceId AS NVARCHAR(10)) + N' (' + i.ItemCode + N')', N', ') WITHIN GROUP (ORDER BY c.Seq)
             FROM @Created c INNER JOIN inventory.Items i ON i.Id = c.ItemId);
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT c.InvoiceId, CASE WHEN c.Seq = 1 THEN N'Updated' ELSE N'Created' END, LEFT(N'Split by item into ' + @Into, 500), @UserId
        FROM @Created c;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT r.Id, r.ItemId, r.ItemCode, r.ItemName, r.LineCount, r.QuantityBase, r.TotalAmount, r.RowVersion, r.ItemCount
    FROM @Created c CROSS APPLY purchase.fn_PurchaseInvoice_Row(c.InvoiceId) r
    ORDER BY c.Seq;
END
GO

/* ================================================================== 9. Get: the mode of the invoice */

-- Re-created (63) from the body of script 47: + OneItemOnly in the header (effective).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, sp.Phone AS SupplierPhone, sp.Email AS SupplierEmail, sp.Address AS SupplierAddress,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo, d.ReceiptMode, d.Notes, d.Status,
           IsContainerBound = CAST(CASE WHEN EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines x
                                                    WHERE x.DocumentId = d.Id AND x.ContainerLineId IS NOT NULL) THEN 1 ELSE 0 END AS BIT),
           ContainerCount = CASE WHEN dt.Code = N'PO'
                                 THEN (SELECT COUNT(DISTINCT cl.ContainerId) FROM logistics.ContainerLines cl
                                       INNER JOIN logistics.Containers c9 ON c9.Id = cl.ContainerId
                                       WHERE cl.PurchaseOrderId = d.Id AND c9.Status <> 8)
                                 ELSE (SELECT COUNT(DISTINCT cl.ContainerId) FROM purchase.PurchaseDocumentLines x
                                       INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
                                       WHERE x.DocumentId = d.Id) END,
           LoadedBase = CASE WHEN dt.Code = N'PO'
                             THEN ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                                          INNER JOIN logistics.Containers c9 ON c9.Id = cl.ContainerId
                                          WHERE cl.PurchaseOrderId = d.Id AND c9.Status <> 8), 0) END,
           ContainerChargesBase = cch.Share,
           ContainersNeeded = need.Containers,     -- (43) invoices: sum over the items of the pieces / pieces per container
           d.ApprovalRequestedAtUtc, d.ApprovalRequestedBy, rqu.FullName AS ApprovalRequestedByName,
           d.ApprovedAtUtc, d.ApprovedBy, apu.FullName AS ApprovedByName, d.ApprovalChannel,
           d.RejectedAtUtc, d.RejectedBy, rju.FullName AS RejectedByName, d.RejectReason,
           OrderedBase = prog.Ordered, InvoicedBase = prog.Invoiced, InDraftInvoicesBase = ISNULL(drf.InDraft, 0),
           InvoicingStatus = CASE WHEN dt.Code <> N'PO' THEN NULL WHEN ISNULL(prog.Invoiced, 0) = 0 THEN 0
                                  WHEN prog.Invoiced >= prog.Ordered THEN 2 ELSE 1 END,      -- 0 not, 1 partially, 2 fully invoiced
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase, d.TotalChargesBase, d.TotalLandedCostBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber, sdt.Code AS SourceDocumentTypeCode,
           d.SourceShortageId, sh.DocumentNumber AS SourceShortageNumber,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.ClosedAtUtc, d.ClosedBy, ku.FullName AS ClosedByName, d.CloseReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion,
           -- (47) supplier payments: posted purchase invoices only (NULL otherwise)
           PaidAmount = pst.PaidAmount, ReturnedAmount = pst.ReturnedAmount, OutstandingAmount = pst.OutstandingAmount, PaymentStatus = pst.PaymentStatus,
           -- (63) supplier invoices: 1 = it holds one item (65029 refuses a second), 0 = it may hold several. Its own mode,
           --      or the setting when it has none (saved before script 63). 0 on orders and returns: not concerned.
           OneItemOnly = CAST(CASE WHEN dt.Code = N'PINV'
                                   THEN COALESCE(d.OneItemOnly, configuration.fn_SettingBool(N'Purchase.OneItemPerInvoice')) ELSE 0 END AS BIT)
    FROM purchase.PurchaseDocuments d
    OUTER APPLY purchase.fn_InvoiceSettlement(d.Id) pst
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN inventory.DocumentTypes sdt ON sdt.Id = src.DocumentTypeId
    LEFT  JOIN inventory.ShortageDocuments sh ON sh.Id = d.SourceShortageId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    LEFT  JOIN security.Users ku ON ku.Id = d.ClosedBy
    LEFT  JOIN security.Users rqu ON rqu.Id = d.ApprovalRequestedBy
    LEFT  JOIN security.Users apu ON apu.Id = d.ApprovedBy
    LEFT  JOIN security.Users rju ON rju.Id = d.RejectedBy
    OUTER APPLY (SELECT Ordered = SUM(pl.QuantityBase), Invoiced = SUM(pl.ReceivedQuantityBase)
                 FROM purchase.PurchaseDocumentLines pl WHERE pl.DocumentId = d.Id) prog
    OUTER APPLY (SELECT InDraft = SUM(x.QuantityBase)
                 FROM purchase.PurchaseDocumentLines pl
                 INNER JOIN purchase.PurchaseDocumentLines x ON x.SourceLineId = pl.Id
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId AND xd.Status = 1
                 WHERE pl.DocumentId = d.Id) drf
    OUTER APPLY (SELECT Share = SUM(a.AmountBase * CAST(x.QuantityBase AS DECIMAL(18,6)) / NULLIF(cl.QuantityBase, 0))
                 FROM purchase.PurchaseDocumentLines x
                 INNER JOIN logistics.ContainerLines cl            ON cl.Id = x.ContainerLineId
                 INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id
                 INNER JOIN logistics.ContainerCharges ch          ON ch.Id = a.ChargeId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1
                 WHERE x.DocumentId = d.Id) cch
    OUTER APPLY (SELECT Containers = CASE WHEN dt.Code = N'PINV'
                                          THEN CAST(SUM(CAST(s.InvoicedBase AS DECIMAL(19,4)) / s.PcsPerContainer) AS DECIMAL(18,2)) END
                 FROM purchase.fn_PurchaseInvoice_ItemContainers(d.Id) s) need
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal,
           l.UnitCostBase, LandedCostBase = l.UnitCostBase, l.FobCostBase, l.AllocatedChargesBase,
           l.ReceivedQuantityBase, l.ReturnedQuantityBase, l.ShippedQuantityBase,
           AllocatedToContainersBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(ct.Allocated, 0)
                                            WHEN l.ContainerLineId IS NOT NULL THEN l.QuantityBase ELSE 0 END,
           TransitBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(ct.Transit, 0)
                              WHEN lct.Status IN (3, 4, 5) THEN l.QuantityBase ELSE 0 END,
           RemainingBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReturnedQuantityBase END,
           AvailableForContainerBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - ISNULL(ct.Allocated, 0) - ISNULL(dir.Qty, 0) END,
           InvoicedDirectBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(dir.Qty, 0) END,
           l.ContainerLineId, ContainerId = lcl.ContainerId, ContainerRef = lct.ContainerRef, ContainerNo = lct.ContainerNo,
           ContainerStatus = lct.Status,
           ContainerChargesBase = CASE WHEN l.ContainerLineId IS NOT NULL THEN ISNULL(lch.Share, 0) END,
           EstimatedLandedCostBase = CASE WHEN l.ContainerLineId IS NOT NULL
                                          THEN COALESCE(lcl.LandedCostBase,
                                                        ISNULL(l.FobCostBase, l.LineTotal / NULLIF(d.ExchangeRate, 0) / NULLIF(l.QuantityBase, 0))
                                                        + ISNULL(lch.Share, 0) / NULLIF(l.QuantityBase, 0)) END,
           InDraftDocumentsBase = ISNULL(dr.Qty, 0),
           AvailableToInvoiceBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase - ISNULL(dr.Qty, 0) END,
           l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           ItemLastCost = i.LastCost, ItemAverageCost = i.AverageCost, ItemFobCost = i.FobCost
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w      ON w.Id = l.WarehouseId
    OUTER APPLY (SELECT Allocated = SUM(cl.QuantityBase),
                        Transit   = SUM(CASE WHEN c.Status IN (3, 4, 5) THEN cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0) ELSE 0 END)
                 FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8) ct
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2 AND dt.Code = N'PO') dir
    LEFT  JOIN logistics.ContainerLines lcl ON lcl.Id = l.ContainerLineId
    LEFT  JOIN logistics.Containers lct     ON lct.Id = lcl.ContainerId
    OUTER APPLY (SELECT Charges = SUM(a.AmountBase)
                 FROM logistics.ContainerChargeAllocations a
                 INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1
                 WHERE a.ContainerLineId = l.ContainerLineId) lcc
    OUTER APPLY (SELECT Share = lcc.Charges * CAST(l.QuantityBase AS DECIMAL(18,6)) / NULLIF(lcl.QuantityBase, 0)) lch
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND xd.Status = 1) dr
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM purchase.PurchaseDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.PurchaseDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    SELECT Relation = N'Source', x.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments d
    INNER JOIN purchase.PurchaseDocuments x ON x.Id = d.SourceDocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE d.Id = @Id
    UNION ALL
    SELECT N'Child', x.Id, dt.Code, dt.Name, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments x
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE x.SourceDocumentId = @Id
    ORDER BY Relation DESC, DocumentDate, Id;

    -- 6: charges of the invoice (kind PINV), of its landed cost adjustments (kind LCA) and, for an import, the charges of
    --    its containers (kind CNT, read-only: DocumentId = container, AdjustmentStatus = charge status) with ShareBase =
    --    the part that falls on this invoice's lines.
    SELECT c.Id, c.DocumentKind, c.DocumentId, SourceNumber = CASE WHEN c.DocumentKind = N'LCA' THEN lca.DocumentNumber ELSE d.DocumentNumber END,
           c.LineNumber, c.ChargeTypeId, ct.ChargeCode, ct.ChargeName, c.Description, c.ProviderPartyId, pp.PartyName AS ProviderName, c.Reference,
           c.CurrencyId, cur.CurrencyCode, c.RateType, c.ExchangeRate, c.Amount, c.AmountBase, c.AllocationMethod, c.IncludeInLandedCost, c.IncludedInSupplierInvoice, c.Notes,
           AllocatedBase = (SELECT SUM(AmountBase) FROM purchase.PurchaseChargeAllocations x WHERE x.ChargeId = c.Id),
           AdjustmentStatus = lca.Status,
           ContainerId = CAST(NULL AS INT), ContainerRef = CAST(NULL AS NVARCHAR(30)), ChargeDate = CAST(NULL AS DATE),
           ChargeStatus = CAST(NULL AS TINYINT), ShareBase = CAST(NULL AS DECIMAL(18,2))
    FROM purchase.PurchaseCharges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = c.CurrencyId
    LEFT  JOIN masterdata.Parties pp ON pp.Id = c.ProviderPartyId
    LEFT  JOIN purchase.PurchaseDocuments d ON d.Id = c.DocumentId AND c.DocumentKind = N'PINV'
    LEFT  JOIN purchase.LandedCostAdjustments lca ON lca.Id = c.DocumentId AND c.DocumentKind = N'LCA'
    WHERE (c.DocumentKind = N'PINV' AND c.DocumentId = @Id)
       OR (c.DocumentKind = N'LCA' AND lca.SourceInvoiceId = @Id)
    UNION ALL
    SELECT ch.Id, N'CNT', ch.ContainerId, cn.ContainerRef,
           CAST(ROW_NUMBER() OVER (ORDER BY cn.ContainerRef, ch.ChargeDate, ch.Id) AS INT),
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName, ch.Reference,
           ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase, ch.AllocationMethod, ch.IncludeInLandedCost,
           CAST(0 AS BIT), ch.Notes,
           ISNULL(s.Share, 0), ch.Status,
           ch.ContainerId, cn.ContainerRef, ch.ChargeDate, ch.Status, CAST(ISNULL(s.Share, 0) AS DECIMAL(18,2))
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers cn   ON cn.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    OUTER APPLY (SELECT Share = SUM(a.AmountBase * CAST(l.QuantityBase AS DECIMAL(18,6)) / NULLIF(cl.QuantityBase, 0))
                 FROM purchase.PurchaseDocumentLines l
                 INNER JOIN logistics.ContainerLines cl            ON cl.Id = l.ContainerLineId
                 INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id AND a.ChargeId = ch.Id
                 WHERE l.DocumentId = @Id) s
    WHERE ch.Status IN (1, 2)
      AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                  INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                  WHERE l.DocumentId = @Id AND cl.ContainerId = ch.ContainerId)
    ORDER BY 2, 3, 5;

    -- 7: containers of the document: for an order the containers carrying its lines, for an invoice its containers.
    SELECT ct.Id, ct.ContainerRef, ct.ContainerNo, ct.Status, ct.DispatchDate, ct.Eta, ct.OffloadedDate,
           ct.CurrentLocation, w.WarehouseCode, w.WarehouseName,
           AllocatedBase = ISNULL(x.Allocated, 0), ReceivedBase = ISNULL(x.Received, 0), InvoicedBase = ISNULL(x.Invoiced, 0),
           ct.ContainerTypeId, ctt.TypeCode AS ContainerTypeCode, ct.PurchaseOrderId
    FROM logistics.Containers ct
    INNER JOIN masterdata.ContainerTypes ctt ON ctt.Id = ct.ContainerTypeId
    LEFT  JOIN masterdata.Warehouses w       ON w.Id = ct.WarehouseId
    CROSS APPLY (SELECT Allocated = SUM(q.Allocated), Received = SUM(q.Received), Invoiced = SUM(q.Invoiced)
                 FROM (SELECT Allocated = cl.QuantityBase, Received = ISNULL(cl.ReceivedQuantityBase, 0),
                              Invoiced = ISNULL((SELECT SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                                                 INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                                                 WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (2, 4)), 0)
                       FROM logistics.ContainerLines cl
                       WHERE cl.ContainerId = ct.Id AND cl.PurchaseOrderId = @Id
                       UNION ALL
                       SELECT l.QuantityBase, l.ReceivedQuantityBase, l.QuantityBase
                       FROM purchase.PurchaseDocumentLines l
                       INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                       WHERE l.DocumentId = @Id AND cl.ContainerId = ct.Id) q) x
    WHERE ct.Status <> 8
      AND (EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = ct.Id AND cl.PurchaseOrderId = @Id)
           OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                      INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                      WHERE l.DocumentId = @Id AND cl.ContainerId = ct.Id))
    ORDER BY ct.ContainerRef;

    -- 8: approval requests and decisions (purchase orders).
    SELECT a.Id, a.RequestNo, a.ApproverUserId, u.FullName AS ApproverName, u.Email AS ApproverEmail,
           a.Status, a.ExpiresAtUtc, a.DecidedAtUtc, a.DecisionNote, a.Channel, a.RequestedAtUtc, ru.FullName AS RequestedByName
    FROM purchase.PurchaseOrderApprovals a
    INNER JOIN security.Users u ON u.Id = a.ApproverUserId
    LEFT  JOIN security.Users ru ON ru.Id = a.RequestedBy
    WHERE a.DocumentId = @Id
    ORDER BY a.RequestNo DESC, a.Id;
END
GO

/* ================================================================== 10. Containers from the invoice: rule 3 by mode */

-- Re-created (63) from the body of script 51: rule 3 (a draft of several items is split by item first) only for an
-- invoice whose mode is one item. The other rules and the figures are unchanged.
CREATE OR ALTER FUNCTION purchase.fn_PurchaseInvoice_ContainerState (@InvoiceId INT)
RETURNS TABLE
AS
RETURN
SELECT d.Id AS InvoiceId, d.DocumentNumber, d.Status, d.ReceiptMode,
       OrderId = o.Id, OrderNo = o.DocumentNumber, OrderStatus = o.Status,
       ln.ItemCount, ItemId = CASE WHEN ln.ItemCount = 1 THEN ln.FirstItemId END,
       NotInContainerQty      = ISNULL(u.NotInContainer, 0),
       OrderLinesAvailableQty = ISNULL(u.Available, 0),
       MaxAddQty              = ISNULL(u.MaxAdd, 0),
       pc.PcsPerContainer,
       LinkableQty            = ISNULL(k.Qty, 0),
       r.FailedRule, r.Reason,
       CanAddContainers = CAST(CASE WHEN r.FailedRule IS NULL THEN 1 ELSE 0 END AS BIT),
       CanTurnOnShipped = CAST(CASE WHEN r.FailedRule = 4 AND d.Status = 1 THEN 1 ELSE 0 END AS BIT),
       CanLink          = CAST(CASE WHEN ISNULL(r.FailedRule, 7) = 7 AND ISNULL(k.Qty, 0) > 0 THEN 1 ELSE 0 END AS BIT),
       LinkReason       = CAST(CASE WHEN ISNULL(r.FailedRule, 7) <> 7 THEN r.Reason
                                    WHEN ISNULL(k.Qty, 0) = 0
                                        THEN N'No container of order ' + ISNULL(o.DocumentNumber, N'(draft)')
                                             + N' has pieces left to link: add a container.' END AS NVARCHAR(400))
FROM purchase.PurchaseDocuments d
INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
LEFT  JOIN purchase.PurchaseDocuments o ON o.Id = d.SourceDocumentId
LEFT  JOIN inventory.DocumentTypes ot   ON ot.Id = o.DocumentTypeId
CROSS APPLY (SELECT Lines = COUNT(*), ItemCount = COUNT(DISTINCT l.ItemId), FirstItemId = MIN(l.ItemId),
                    Typed = SUM(CASE WHEN l.SourceLineId IS NULL THEN 1 ELSE 0 END)
             FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = d.Id) ln
-- per order line the invoice has pieces of outside containers: those pieces, and what the order line still allows
OUTER APPLY (SELECT NotInContainer = SUM(x.Unlinked), Available = SUM(x.Allowed),
                    MaxAdd = SUM(CASE WHEN x.Unlinked < x.Allowed THEN x.Unlinked ELSE x.Allowed END)
             FROM (SELECT Unlinked = un.UnlinkedBase,
                          Allowed = CASE WHEN a.Qty > 0 THEN a.Qty ELSE 0 END
                   FROM purchase.fn_PurchaseInvoice_Unlinked(d.Id) un
                   INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = un.PoLineId
                   CROSS APPLY (SELECT Qty = pol.QuantityBase
                                    - ISNULL((SELECT SUM(dl.QuantityBase) FROM purchase.PurchaseDocumentLines dl
                                              INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = dl.DocumentId
                                              WHERE dl.SourceLineId = pol.Id AND dl.ContainerLineId IS NULL AND dl.DocumentId <> d.Id
                                                AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2), 0)
                                    - ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                                              INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                                              WHERE cl.PoLineId = pol.Id AND c.Status <> 8), 0)) a) x) u
OUTER APPLY (SELECT PcsPerContainer = MAX(s.PcsPerContainer) FROM purchase.fn_PurchaseInvoice_ItemContainers(d.Id) s) pc
-- what the order's Draft / Confirmed containers have loaded and not invoiced yet, on the order lines the invoice has outside
OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase - ISNULL(q.Qty, 0))
             FROM logistics.ContainerLines cl
             INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
             OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                          INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                          WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
             WHERE cl.PurchaseOrderId = o.Id AND c.Status IN (1, 2) AND cl.QuantityBase - ISNULL(q.Qty, 0) > 0
               AND cl.PoLineId IN (SELECT PoLineId FROM purchase.fn_PurchaseInvoice_Unlinked(d.Id))) k
-- (63) the invoice's mode: rule 3 (split a draft of several items first) concerns a one-item invoice only
CROSS APPLY (SELECT OneItemOnly = COALESCE(d.OneItemOnly, configuration.fn_SettingBool(N'Purchase.OneItemPerInvoice'))) oi
CROSS APPLY (SELECT FailedRule = CAST(CASE
                        WHEN dt.Code <> N'PINV' OR d.Status NOT IN (1, 2) THEN 1
                        WHEN o.Id IS NULL OR ot.Code <> N'PO' OR ln.Typed > 0 THEN 2
                        WHEN ln.ItemCount > 1 AND d.Status = 1 AND oi.OneItemOnly = 1 THEN 3
                        WHEN d.ReceiptMode <> 2 THEN 4
                        WHEN o.Status NOT IN (2, 4) THEN 5
                        WHEN ISNULL(u.NotInContainer, 0) = 0 THEN 6
                        WHEN ISNULL(u.Available, 0) = 0 THEN 7 END AS TINYINT),
                    Reason = CAST(CASE
                        WHEN dt.Code <> N'PINV' THEN N'Only a purchase invoice can take containers.'
                        WHEN d.Status NOT IN (1, 2) THEN N'A cancelled invoice cannot be linked to containers.'
                        WHEN o.Id IS NULL OR ot.Code <> N'PO' OR ln.Typed > 0
                            THEN N'Only a purchase invoice created from a purchase order can be linked to containers.'
                        WHEN ln.ItemCount > 1 AND d.Status = 1 AND oi.OneItemOnly = 1
                            THEN N'This invoice holds ' + CAST(ln.ItemCount AS NVARCHAR(10))
                                 + N' items and a supplier invoice holds one: split it by item first.'
                        WHEN d.ReceiptMode <> 2 AND d.Status = 1
                            THEN N'Turn on "Shipped in containers" first: the goods will then enter the stock at the container offload.'
                        WHEN d.ReceiptMode <> 2 THEN N'This invoice was received when it was posted: it cannot be linked to containers.'
                        WHEN o.Status NOT IN (2, 4)
                            THEN N'Order ' + ISNULL(o.DocumentNumber, N'(draft)') + N' is '
                                 + CASE o.Status WHEN 1 THEN N'a draft' WHEN 3 THEN N'cancelled' ELSE N'waiting for approval' END
                                 + N': containers are made from an approved order.'
                        WHEN ln.Lines = 0 THEN N'This invoice has no lines yet.'
                        WHEN ISNULL(u.NotInContainer, 0) = 0 THEN N'Every piece of this invoice is already in a container.'
                        WHEN ISNULL(u.Available, 0) = 0
                            THEN N'Order ' + o.DocumentNumber + N' allows no more pieces: its lines are already loaded in containers'
                                 + N' or invoiced outside containers.' END AS NVARCHAR(400))) r
WHERE d.Id = @InvoiceId;
GO

/* ================================================================== 11. The list: each supplier invoice's mode */

-- Re-created (63) from the body of script 47: + OneItemOnly (effective), so the list tells an invoice of several items
-- (mode 0) from an invoice of one item that holds several (mode 1, saved before that rule: Post refuses it, 65029, until
-- it is split). Every other column, filter and sort is unchanged.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Search
    @DocumentTypeCode NVARCHAR(20) = NULL,     -- PO | PINV | PRET | NULL = whole family
    @Search           NVARCHAR(100) = NULL,    -- number, supplier / exporter reference, commercial invoice no., supplier code/name, notes,
                                               -- (45) the item code of a supplier invoice
    @BranchId         INT          = NULL,
    @WarehouseId      INT          = NULL,
    @SupplierId       INT          = NULL,
    @Status           TINYINT      = NULL,     -- 1 Draft | 2 Posted (PO: approved) | 3 Cancelled | 4 Closed | 5 Pending approval
    @InvoicingStatus  TINYINT      = NULL,     -- purchase orders: 0 not invoiced | 1 partially | 2 fully
    @DateFrom         DATE         = NULL,
    @DateTo           DATE         = NULL,
    @SortColumn       NVARCHAR(30) = N'DocumentDate',  -- DocumentNumber | DocumentDate | SupplierName | Status | TotalAmount | CreatedAtUtc
    @SortDirection    NVARCHAR(4)  = N'DESC',
    @PageNumber       INT          = 1,
    @PageSize         INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @DocumentTypeCode = NULLIF(LTRIM(RTRIM(@DocumentTypeCode)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'SupplierName', N'Status', N'TotalAmount', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);
    -- (63) the setting, read once: the mode of a supplier invoice created before script 63 (OneItemOnly NULL)
    DECLARE @OneItemSetting BIT = configuration.fn_SettingBool(N'Purchase.OneItemPerInvoice');

    SELECT d.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate, d.BranchId, b.BranchName, d.WarehouseId, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, c.CurrencyCode, c.Symbol AS CurrencySymbol, c.DecimalPlaces, d.ExchangeRate,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo, d.ReceiptMode,
           d.Status, d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber,
           ReceivedPercent = CASE WHEN dt.Code = N'PO' AND ISNULL(prog.Ordered, 0) > 0 THEN CAST(100.0 * prog.Invoiced / prog.Ordered AS DECIMAL(5,1)) END,
           InvoicedPercent = CASE WHEN dt.Code = N'PO' AND ISNULL(prog.Ordered, 0) > 0 THEN CAST(100.0 * prog.Invoiced / prog.Ordered AS DECIMAL(5,1)) END,
           InvoicingStatus = CASE WHEN dt.Code <> N'PO' THEN NULL WHEN ISNULL(prog.Invoiced, 0) = 0 THEN 0
                                  WHEN prog.Invoiced >= prog.Ordered THEN 2 ELSE 1 END,
           DraftInvoiceCount = CASE WHEN dt.Code = N'PO' THEN (SELECT COUNT(*) FROM purchase.PurchaseDocuments x WHERE x.SourceDocumentId = d.Id AND x.Status = 1) END,
           -- (45) the item of a supplier invoice (the one of its first line) and how many it holds (more than 1: an invoice of
           -- several items, 63, or one of one item made before 45)
           ItemId = itm.ItemId, ItemCode = itm.ItemCode, ItemName = itm.ItemName, ItemCount = itm.ItemCount,
           -- (63) a supplier invoice's mode (its own, else the setting): 1 one item, 0 several items; NULL on orders and returns
           OneItemOnly = CAST(CASE WHEN dt.Code = N'PINV' THEN COALESCE(d.OneItemOnly, @OneItemSetting) END AS BIT),
           d.ApprovalRequestedAtUtc, d.ApprovedAtUtc, apu.FullName AS ApprovedByName,
           d.PostedAtUtc, pu.FullName AS PostedByName, d.CancelledAtUtc, d.ClosedAtUtc,
           d.CreatedAtUtc, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.RowVersion,
           -- (47) supplier payments: posted purchase invoices only (NULL otherwise)
           PaidAmount = pst.PaidAmount, ReturnedAmount = pst.ReturnedAmount, OutstandingAmount = pst.OutstandingAmount, PaymentStatus = pst.PaymentStatus,
           COUNT(*) OVER () AS TotalCount
    FROM purchase.PurchaseDocuments d
    OUTER APPLY purchase.fn_InvoiceSettlement(d.Id) pst
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users apu ON apu.Id = d.ApprovedBy
    OUTER APPLY (SELECT Ordered = SUM(QuantityBase), Invoiced = SUM(ReceivedQuantityBase)
                 FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id) prog
    OUTER APPLY (SELECT TOP (1) fl.ItemId, fi.ItemCode, fi.ItemName,
                        ItemCount = (SELECT COUNT(DISTINCT ItemId) FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id)
                 FROM purchase.PurchaseDocumentLines fl INNER JOIN inventory.Items fi ON fi.Id = fl.ItemId
                 WHERE fl.DocumentId = d.Id AND dt.Code = N'PINV'
                 ORDER BY fl.LineNumber) itm
    WHERE dt.Family = N'Purchase'
      AND (@DocumentTypeCode IS NULL OR dt.Code = @DocumentTypeCode)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.SupplierReference LIKE N'%' + @Search + N'%'
           OR d.ExporterReference LIKE N'%' + @Search + N'%' OR d.CommercialInvoiceNo LIKE N'%' + @Search + N'%'
           OR sp.PartyCode LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%' OR d.Notes LIKE N'%' + @Search + N'%'
           OR (dt.Code = N'PINV' AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines sl INNER JOIN inventory.Items si ON si.Id = sl.ItemId
                                             WHERE sl.DocumentId = d.Id AND si.ItemCode LIKE N'%' + @Search + N'%')))
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR d.WarehouseId = @WarehouseId)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Status IS NULL OR d.Status = @Status)
      AND (@InvoicingStatus IS NULL OR (dt.Code = N'PO' AND
           CASE WHEN ISNULL(prog.Invoiced, 0) = 0 THEN 0 WHEN prog.Invoiced >= prog.Ordered THEN 2 ELSE 1 END = @InvoicingStatus))
      AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'SupplierName' THEN sp.PartyName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'SupplierName' THEN sp.PartyName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'TotalAmount' THEN d.TotalAmount END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'TotalAmount' THEN d.TotalAmount END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END DESC,
        d.DocumentDate DESC, d.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

/* ================================================================== 12. Check */

SELECT o.ObjectName, ObjectType = ISNULL(so.type_desc, N'MISSING')
FROM (VALUES (N'purchase.fn_PurchaseInvoice_Row'), (N'purchase.fn_PurchaseInvoice_ContainerState'),
             (N'purchase.usp_PurchaseDocument_Save'), (N'purchase.usp_PurchaseDocument_Post'),
             (N'purchase.usp_PurchaseDocument_CreateFromContainers'), (N'purchase.usp_PurchaseDocument_CreateFromSource'),
             (N'purchase.usp_PurchaseDocument_SplitByItem'), (N'purchase.usp_PurchaseDocument_Get'),
             (N'purchase.usp_PurchaseDocument_Search')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(o.ObjectName)
ORDER BY ObjectType, o.ObjectName;                                    -- expected 9: 2 functions, 7 procedures, none MISSING

-- The setting and its value now; the column.
SELECT d.SettingKey, d.GroupName, d.DefaultValue, d.IsPublic, Value = configuration.fn_SettingValue(d.SettingKey),
       OneItemOnlyColumn = CASE WHEN COL_LENGTH(N'purchase.PurchaseDocuments', N'OneItemOnly') IS NULL THEN N'MISSING' ELSE N'ok' END
FROM configuration.SettingDefinitions d
WHERE d.SettingKey = N'Purchase.OneItemPerInvoice';                   -- expected 1 row, column ok

-- The supplier invoices by mode: 1 one item, 0 several items, NULL = created before script 63 (they follow the setting).
SELECT Mode = CASE d.OneItemOnly WHEN 1 THEN N'one item' WHEN 0 THEN N'several items' ELSE N'follows the setting' END,
       Drafts = SUM(CASE WHEN d.Status = 1 THEN 1 ELSE 0 END), Invoices = COUNT(*)
FROM purchase.PurchaseDocuments d
INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
WHERE dt.Code = N'PINV'
GROUP BY d.OneItemOnly
ORDER BY d.OneItemOnly DESC;

-- Draft supplier invoices of one item (by their mode) that hold several: they cannot be posted - Split by item first.
SELECT d.Id, d.DocumentNumber, Supplier = p.PartyName, ItemCount = COUNT(DISTINCT l.ItemId)
FROM purchase.PurchaseDocuments d
INNER JOIN inventory.DocumentTypes dt       ON dt.Id = d.DocumentTypeId
INNER JOIN purchase.PurchaseDocumentLines l ON l.DocumentId = d.Id
LEFT  JOIN masterdata.Parties p             ON p.Id = d.SupplierId
WHERE dt.Code = N'PINV' AND d.Status = 1
  AND COALESCE(d.OneItemOnly, configuration.fn_SettingBool(N'Purchase.OneItemPerInvoice')) = 1
GROUP BY d.Id, d.DocumentNumber, p.PartyName
HAVING COUNT(DISTINCT l.ItemId) > 1
ORDER BY d.Id;

PRINT 'Script 63 applied: one item per supplier invoice is optional - setting Purchase.OneItemPerInvoice, each invoice''s mode (OneItemOnly), one invoice per item or one invoice from an order or its containers.';
GO

SET NOEXEC OFF;
GO
