SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 94: INVENTORY - WHO MAY SEE ITEM COSTS (prompt 51)

   One permission, inventory.costs.view "View item costs" (Inventory, 406, right after View Stock Valuation), decides who
   sees what an item costs - its average, last and FOB cost and its stock value - on Item Definition (card, list, item
   search), the item's Stock Balance and Stock Movement, Inventory In / Out / BIVAC Out, goods receipts, Shortages,
   transfer orders and the Dashboard.

     1. GRANTED ONCE per database (recorded in script 89's inventory.OneTimeSteps, so a database whose row the catalog
        sync inserted first is still granted at this script's first run), to the system roles and to every role holding
        one of the 14 permissions whose answers carry an item cost today: View / Create / Edit items, View Stock
        Valuation, View / Create Inventory In, Inventory Out, BIVAC Out, Shortage Plans and Goods Receipts. Nobody loses a
        figure on the day this runs. Untick it on Role Permissions afterwards: it is never granted again (the start-up
        sync of the catalog gives it to the system roles only).
     2. THE SERVER STRIPS, THE PAGE HIDES (the API's part, not this script's): without it every such field leaves the API
        null (never 0), the exports leave their cost columns out, a list is not sorted by a hidden figure, and the pages
        decide by the permission not to draw the column. It hides, it never blocks: no new refusal, no new error number.
        A change takes effect at the user's next sign-in or token refresh.
     3. AN INVENTORY IN LINE WITHOUT A COST TAKES THE ITEM'S COST: its last cost when it is not 0, else its average (else
        0), per unit of the line (inventory.usp_StockDocument_Save). It took 0. Such a line comes from a reader who may
        not see item costs (the API drops the cost he sends, and sends back a saved line's own cost when the line's id
        names a saved line of the same item and unit), from a type whose cost cannot be typed ("Price / cost editable"
        off: it posted at 0 and dragged the average down), or from an import row without a cost. A cost typed on a line
        is stored as typed, 0 included. NULL in inventory.tvp_StockDocumentLine.UnitCost now means "the item's cost" on
        an In (the type's own comment, "NULL = 0 for In", is older: a table type is never re-created). An Out still takes
        the average, whatever is sent. A goods receipt line without an order and without a cost follows the same rule,
        applied by the API before purchase.usp_GoodsReceipt_Save (not re-created: its own default, the last cost even
        when it is 0, is what the API no longer leaves it).
     4. NOT THIS PERMISSION'S: Stock Valuation (View Stock Valuation), purchase orders, invoices and returns, landed cost
        adjustments, containers (their invoices, charges, estimates and landed cost per item), sales cost and margin and
        Sales Profit (View Sales Profit). So to hide every cost from a role, untick View item costs, View Stock Valuation
        and View Sales Profit, and also View Containers (a container shows its invoices' amounts, its charges and its
        goods' landed cost), View and Post Purchase Invoices (an invoice's landed costs, its "Cost of received goods" and
        the estimate before posting), View Landed Cost Adjustments and Create Purchase Orders (a purchase line saved
        without a price takes the item's last cost).

   Objects
     New data, once    security.Permissions inventory.costs.view and its once-grant (security.RolePermissions)
     Re-created        inventory.usp_StockDocument_Save    Re-created (94) from the body of script 29: + a line without a
                                                           cost on an In takes the item's last cost, else its average (the
                                                           INSERT of the lines; every other statement word for word)

   Errors: no new number.

   Not changed: Stock Valuation, sales costs and Sales Profit, purchase documents, landed cost adjustments, container
   charges; how an Inventory In posts and costs (inventory.usp_StockDocument_ValidateInput, _Post, _Cancel,
   inventory.usp_Item_ApplyReceipts, inventory.usp_Item_RebuildCosts); a cost typed on a line; an Out's cost; every other
   permission and grant. No table, column, type, view or error number.

   Requires scripts 29, 75 and 89 (Schema.sql runs them first). Idempotent, additive: re-applied at every API start-up, and
   builds a brand-new empty database.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'inventory.usp_StockDocument_Save', N'P') IS NULL
   OR NOT EXISTS (SELECT 1 FROM security.Permissions WHERE Code = N'inventory.valuation.view')
   OR OBJECT_ID(N'inventory.OneTimeSteps', N'U') IS NULL
    THROW 62000, 'Script 94 requires scripts 29, 75 and 89: apply them first.', 1;
GO

/* ================================================================== 1. inventory.costs.view "View item costs", granted once */

-- (94) THE PERMISSION, GRANTED ONCE PER DATABASE (script 89's inventory.OneTimeSteps, step 94.CostsViewGrant): a role
--      unticked later is never re-granted. Its row is normally first inserted here (Schema.sql runs before the API's
--      catalog sync, which only upserts the texts and gives every permission to the system roles); should the sync have
--      inserted it first (an API built with the catalog entry started once on a database without this script), the
--      grant still runs at this script's first run, so no role silently loses its costs. The texts are PermissionCatalog.cs's.
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;
    MERGE security.Permissions AS target
    USING (VALUES (N'inventory.costs.view', N'View item costs', N'Inventory',
                   N'See item costs (average, last, FOB) and stock values on Item Definition, Inventory In / Out / BIVAC Out, goods receipts, Shortages, transfers and the Dashboard. Without it an Inventory In takes the item''s last cost, else its average.',
                   406)) AS source (Code, Name, Module, Description, SortOrder)
    ON target.Code = source.Code
    WHEN MATCHED AND (target.Name <> source.Name OR target.Module <> source.Module
                      OR ISNULL(target.Description, N'') <> source.Description OR target.SortOrder <> source.SortOrder) THEN
        UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (Code, Name, Module, Description, SortOrder)
        VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);

    IF NOT EXISTS (SELECT 1 FROM inventory.OneTimeSteps WHERE StepCode = N'94.CostsViewGrant')
    BEGIN
        DECLARE @PermissionId INT = (SELECT p.Id FROM security.Permissions p WHERE p.Code = N'inventory.costs.view');
        -- (94) EVERY ROLE THAT SAW AN ITEM COST UNTIL TODAY: the permissions whose answers carried one (6.4.3).
        INSERT INTO security.RolePermissions (RoleId, PermissionId)
        SELECT r.Id, @PermissionId
        FROM security.Roles r
        WHERE (r.IsSystem = 1
               OR EXISTS (SELECT 1 FROM security.RolePermissions rp INNER JOIN security.Permissions p ON p.Id = rp.PermissionId
                          WHERE rp.RoleId = r.Id
                            AND p.Code IN (N'inventory.items.view', N'inventory.items.create', N'inventory.items.edit',
                                           N'inventory.valuation.view', N'inventory.stockin.view', N'inventory.stockin.create',
                                           N'inventory.stockout.view', N'inventory.stockout.create',
                                           N'inventory.bivacout.view', N'inventory.bivacout.create',
                                           N'inventory.shortages.view', N'inventory.shortages.create',
                                           N'purchase.goodsreceipts.view', N'purchase.goodsreceipts.create')))
          AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = @PermissionId);
        DECLARE @Grants INT = @@ROWCOUNT;
        INSERT INTO inventory.OneTimeSteps (StepCode, DoneAtUtc, Progress, Details)
        VALUES (N'94.CostsViewGrant', SYSUTCDATETIME(), @Grants, N'View item costs granted once to the roles that saw item costs.');
        PRINT 'Item cost permission granted once: ' + CAST(@Grants AS NVARCHAR(10)) + ' role grant(s).';
    END
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO

/* ================================================================== 2. inventory.usp_StockDocument_Save */

-- Re-created (94) from the body of script 29: + A LINE WITHOUT A COST ON AN IN TAKES THE ITEM'S COST - its last cost
-- when it is not 0, else its average (else 0), per unit of the line (it took 0). Only the INSERT of the lines changes;
-- every other statement is script 29's word for word. A last cost of 0 never wins over a real average: a free goods
-- receipt line sets LastCost = 0 (script 79 learnt the same, "so goods never enter at nothing").
CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Save
    @Id               INT            = NULL,   -- NULL = create
    @DocumentTypeCode NVARCHAR(20),
    @DocumentDate     DATE,
    @BranchId         INT,
    @WarehouseId      INT = NULL,
    @ReasonId         INT            = NULL,
    @ReferenceNo      NVARCHAR(100)  = NULL,
    @Notes            NVARCHAR(1000) = NULL,
    @Lines            inventory.tvp_StockDocumentLine READONLY,
    @RowVersion       BINARY(8)      = NULL,
    @UserId           INT            = NULL,
    @NewId            INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* The warehouse lives on the LINES. The header keeps one so that document lists, filters,
       reports and exports still have a warehouse to show; when the caller does not send one it is
       taken from the first line. */
    IF @WarehouseId IS NULL
        SELECT TOP (1) @WarehouseId = WarehouseId FROM @Lines ORDER BY LineNumber;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    DECLARE @TypeId INT, @Direction SMALLINT, @CurrencyId INT;
    EXEC inventory.usp_StockDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @BranchId, @WarehouseId, @ReasonId, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @CurrencyId OUTPUT;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM inventory.StockDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 62006, 'Document not found.', 1;
        IF @Status <> 1 THROW 62005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 62000, 'The document type cannot be changed.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO inventory.StockDocuments (DocumentTypeId, DocumentNumber, DocumentDate, BranchId, WarehouseId, ReasonId,
                                                  ReferenceNo, CurrencyId, ExchangeRate, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @BranchId, @WarehouseId, @ReasonId, @ReferenceNo, @CurrencyId, 1, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)'), @UserId);
        END
        ELSE
        BEGIN
            UPDATE inventory.StockDocuments
            SET DocumentDate = @DocumentDate, BranchId = @BranchId, WarehouseId = @WarehouseId, ReasonId = @ReasonId,
                ReferenceNo = @ReferenceNo, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM inventory.StockDocumentLines WHERE DocumentId = @Id;

            INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        -- Lines: each line carries its OWN warehouse; Out documents take the item's moving average cost (per unit).
        -- (94) A LINE WITHOUT A COST on an In - a reader who may not see item costs, a type whose cost cannot be typed, an
        --      import row without one - takes the item's last cost (when it is not 0), else its average (else 0), per
        --      unit of the line: the default the page proposes. It took 0. The API keeps a saved line's own cost by
        --      sending it back; a NULL here always means "the item's cost".
        INSERT INTO inventory.StockDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula, UnitCost, Notes)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, l.WarehouseId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
               CASE WHEN @Direction = -1 THEN ISNULL(inventory.fn_AverageCost(l.ItemId), 0) * iu.PackingFormula
                    ELSE ISNULL(l.UnitCost, ROUND(COALESCE(NULLIF(i.LastCost, 0), i.AverageCost, 0) * iu.PackingFormula, 4)) END,
               NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
        INNER JOIN inventory.Items i      ON i.Id = l.ItemId;

        UPDATE d SET TotalItems = x.Items, TotalQuantity = x.Qty, TotalCost = x.Cost
        FROM inventory.StockDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty, ISNULL(SUM(LineTotal), 0) AS Cost
                     FROM inventory.StockDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 3. Check */

-- 94a: the permission and how many roles hold it; 94b: each role, and whether it holds it
SELECT p.Code, p.Name, p.Module, p.SortOrder, Roles = (SELECT COUNT(*) FROM security.RolePermissions rp WHERE rp.PermissionId = p.Id)
FROM security.Permissions p WHERE p.Code = N'inventory.costs.view';
SELECT r.Name, r.IsSystem,
       HoldsItemCosts = CASE WHEN EXISTS (SELECT 1 FROM security.RolePermissions rp INNER JOIN security.Permissions p ON p.Id = rp.PermissionId
                                          WHERE rp.RoleId = r.Id AND p.Code = N'inventory.costs.view') THEN 1 ELSE 0 END
FROM security.Roles r ORDER BY r.IsSystem DESC, r.Name;
PRINT 'Script 94 applied: View item costs (inventory.costs.view); an Inventory In line without a cost takes the item''s last cost, else its average.';
GO
