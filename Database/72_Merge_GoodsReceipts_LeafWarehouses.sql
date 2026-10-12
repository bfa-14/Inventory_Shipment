SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 72: MERGE - GOODS RECEIPTS (63-67) MEET LEAF WAREHOUSES OF ANY BRANCH (68-71)

   Why this script exists
     Two lines of work split after script 62 and both numbered their next scripts from 63. GitHub main: 63 one item per
     supplier invoice optional, 64 + 65 goods receipts (65 is the one-way switch: invoices no longer move stock, the
     container offload is refused), 66 BIVAC Out, 67 attachments of items. GitLab main (Ali): the dashboard, Inventory
     In / Out lines of any branch, line warehouses at the bottom of the tree, a used warehouse cannot become a parent.
     When the two were merged, Ali's scripts were renumbered 68-71 (only the numbers they give themselves changed: they
     were already applied on his database) and run AFTER 63-67 in Schema.sql.
     Scripts 69 and 70 re-create, from bodies written before 63-67, six procedures that 63-67 had changed too. Left at
     that, every start-up would end with those six WITHOUT the goods receipts, the BIVAC check and the refused offload.
     This script re-creates each one from its LAST body (Ali's, in 69 / 70) plus our change, so that it holds BOTH; it
     gives the goods receipts the warehouse rule Ali gave every other document; and it gives Ali's dashboard the goods
     receipts.

   The objects both sides re-create (every CREATE OR ALTER of 63-67 intersected with those of 68-71, functions, views
   and types included), and what each holds now
     inventory.usp_StockDocument_ValidateInput   66: a BIVAC-only type (BIVAC Out) takes BIVAC items only (62000).
                                                 69: neither the header warehouse nor a line is limited to the branch.
                                                 70: a line's warehouse is at the bottom of the tree.
     inventory.usp_StockDocument_Post            66: the BIVAC check again at posting. 69: no branch check, each stock
                                                 movement in the branch of ITS warehouse. 70: the leaf check.
     purchase.usp_PurchaseDocument_ValidateInput 65: only PO, PINV, PRET are purchase documents (65008). 70: leaf lines.
     purchase.usp_PurchaseDocument_Post          63 + 65: one item per invoice by mode; an invoice moves no stock and
                                                 marks UsesGoodsReceipts; rematch and true-up; "Receive the goods now";
                                                 returns capped by what was received; the order closes when invoiced
                                                 and received. 70: a line in a parent warehouse is refused (65000).
     sales.usp_InvoiceImport_Validate            66: a row of a BIVAC-only type must be a BIVAC item. 70: the default
                                                 warehouse may be of any branch but is a leaf; a row naming a parent is
                                                 an Error.
     logistics.usp_Container_Offload             65: refused (69010), containers are received with a goods receipt.
                                                 70: the offloading warehouse must be a leaf. It stays REFUSED: 70's
                                                 rule moves to the container's goods receipt, below.

   The goods receipts take Ali's warehouse rule (script 70)
     A goods receipt puts stock into its warehouses, so they follow the rule of the documents' lines: a warehouse with
     warehouses under it is a group, not a place that holds stock. 63000, in Ali's sentence: "The warehouse {code} has
     warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree."
       - A CONTAINER's receipt: "Receive into" (every line) at the bottom of the tree, and still of the container's
         branch - the rule of its own that script 70 kept for the offload it replaces.
       - An ORDER's, an INVOICE's, a receipt WITHOUT AN ORDER: each line's warehouse at the bottom of the tree, of any
         branch (as it already was); "Receive into" too, since it is the lines' default (as the default warehouse of
         the Excel import is, script 70).
     purchase.usp_GoodsReceipt_Save               refuses a parent on save (the header, a local line).
     purchase.fn_GoodsReceipt_PostCheck           the same at posting (a draft saved before this script):
                                                  usp_GoodsReceipt_Post raises its first row, and usp_GoodsReceipt_Get
                                                  shows it as the reason Post is blocked - so Post itself is unchanged.
     purchase.usp_GoodsReceipt_CreateForContainer proposes the container's warehouse only when it is also a leaf; else
                                                  the draft is made without one ("warehouse to choose").
     purchase.usp_GoodsReceipt_CreateForMovement  the Delivery's drafts made without a warehouse say why: "choose the
                                                  warehouse (LUB-WH, the container's, has warehouses under it: ...)".
     logistics.usp_Movement_Get                   WarehouseInBranch (what the Complete dialog of a Delivery announces)
                                                  says what CreateForContainer will take: a leaf too.
     Unchanged: usp_GoodsReceipt_CreateFromOrder / _CreateFromInvoice. Their lines default to the order or invoice
     line's warehouse; a parent there (a document saved before script 70) is refused by Save with the line's own
     sentence, and the dialog lets the reader choose another.
     masterdata.fn_Warehouse_IsUsed (71)          + purchase.GoodsReceipts ("Receive into", a draft too) and
                                                  purchase.GoodsReceiptLines: a warehouse a goods receipt names cannot
                                                  become a parent. BIVAC Out is a stock document: already counted.

   Ali's dashboard (68) takes the goods receipts
     It was written before them and counted "on order" as ordered - ReceivedQuantityBase, which is what was INVOICED:
     since script 65 an invoice brings no goods in, so received goods not invoiced yet still showed as on order, and
     goods invoiced but not received did not.
     reporting.usp_Dashboard_Summary              5 "on the way": OnOrderPieces = what the open (and closed) orders still
                                                  have to receive (fn_PoLine_Progress.OutstandingBase, rule 19) less the
                                                  pieces travelling in containers that left the supplier, which
                                                  InTransitPieces counts: the "On order" of Shortages and of the item;
                                                  OpenOrders = the orders with something still to receive.
                                                  6 drafts: + the draft goods receipts (Kind Purchase, TypeCode GRN).
     The API and the web list the GRN and BIV_OUT drafts for the readers who may see them.

   Errors: no new number (63000 goods receipts, 62000 / 65000 / 61008 as Ali's 69 and 70).

   Requires scripts 64, 65, 66, 67 and 68-71 (Schema.sql runs them first). Idempotent, additive (CREATE OR ALTER and a
   Check of SELECTs): re-applied at every API start-up, and builds a brand-new empty database (every table and function
   it reads exists by then).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'purchase.GoodsReceipts', N'U') IS NULL                       -- 64
   OR OBJECT_ID(N'purchase.GoodsReceiptSwitch', N'U') IS NULL                -- 64 (the switch row is written by 65)
   OR OBJECT_ID(N'logistics.fn_Container_CloseBlock', N'IF') IS NULL         -- 65
   OR COL_LENGTH(N'inventory.DocumentTypes', N'BivacItemsOnly') IS NULL      -- 66
   OR OBJECT_ID(N'inventory.usp_ItemFile_List', N'P') IS NULL                -- 67
   OR OBJECT_ID(N'reporting.usp_Dashboard_Summary', N'P') IS NULL            -- 68
   OR OBJECT_ID(N'masterdata.fn_Warehouse_IsLeaf', N'FN') IS NULL            -- 70
   OR OBJECT_ID(N'masterdata.fn_Warehouse_IsUsed', N'FN') IS NULL            -- 71
BEGIN
    RAISERROR ('Run scripts 64 to 71 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. Used warehouses: goods receipts count too */

-- Re-created (72) from the body of script 71: + purchase.GoodsReceipts and purchase.GoodsReceiptLines. A goods receipt
-- names its warehouse as surely as an invoice line does (and puts stock there once posted), so a warehouse it names
-- cannot become a parent either. Before the procedures below, which do not call it, and usp_Warehouse_Lookup /
-- _Create / _Update (71), which do.
CREATE OR ALTER FUNCTION masterdata.fn_Warehouse_IsUsed (@WarehouseId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (SELECT 1 FROM inventory.StockMovements          WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM inventory.StockDocumentLines      WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM inventory.StockDocuments          WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM sales.SalesDocumentLines          WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM sales.SalesDocuments              WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines    WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.PurchaseDocuments        WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM logistics.Containers              WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM inventory.CostAdjustments         WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.LandedCostAdjustmentLines WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM sales.OutOfStockSaleAudit         WHERE WarehouseId = @WarehouseId)
                  -- (72) a goods receipt names it: "Receive into" (a draft too) or a line's warehouse
                  OR EXISTS (SELECT 1 FROM purchase.GoodsReceipts            WHERE WarehouseId = @WarehouseId)
                  OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines        WHERE WarehouseId = @WarehouseId)
                THEN 1 ELSE 0 END;
END
GO

/* ================================================================== 2. Inventory In / Out / BIVAC Out: save */

-- Re-created (72) from the body of script 70 (Ali: 69 no branch limit on the header warehouse or the lines, 70 a line's
-- warehouse at the bottom of the tree) + script 66's BIVAC line check of a BivacItemsOnly type.
CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_ValidateInput
    @DocumentTypeCode NVARCHAR(20),
    @DocumentDate     DATE,
    @BranchId         INT,
    @WarehouseId      INT = NULL,
    @ReasonId         INT,
    @Lines            inventory.tvp_StockDocumentLine READONLY,
    @DocumentTypeId   INT OUTPUT,
    @StockDirection   SMALLINT OUTPUT,
    @CurrencyId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RequiresReason BIT, @BivacOnly BIT, @TypeName NVARCHAR(100);
    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection, @RequiresReason = RequiresReason,
           @BivacOnly = BivacItemsOnly, @TypeName = Name   -- (66)
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Inventory' AND IsActive = 1;
    IF @DocumentTypeId IS NULL
        THROW 62008, 'Document type not found, inactive, or not an inventory document.', 1;

    IF @DocumentDate IS NULL THROW 62000, 'Document Date is required.', 1;
    /* ONE DAY OF TOLERANCE, because this compares a LOCAL date against a UTC one. The date on the
       document is the one the reader sees on their own clock; SYSUTCDATETIME() is the server's in
       UTC. East of Greenwich the two disagree for the first hours after midnight - at 00:20 in
       Beirut (UTC+3) it is still yesterday in UTC, so a document dated today was refused as being
       in the future. A day covers every offset without letting a genuinely future date through by
       more than one. */
    IF @DocumentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 62000, 'Document Date cannot be in the future.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 62008, 'Branch not found or inactive.', 1;
    IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1)
        THROW 62008, 'The default warehouse must be an active warehouse.', 1;
    IF @RequiresReason = 1 AND @ReasonId IS NULL THROW 62000, 'Reason is required.', 1;
    IF @ReasonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockReasons
                                             WHERE Id = @ReasonId AND IsActive = 1
                                               AND (AppliesTo = N'Both' OR (AppliesTo = N'In' AND @StockDirection = 1) OR (AppliesTo = N'Out' AND @StockDirection = -1)))
        THROW 62008, 'Reason not found, inactive, or not applicable to this document type.', 1;

    SELECT @CurrencyId = Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1;
    IF @CurrencyId IS NULL THROW 62008, 'No active base currency is configured.', 1;

    -- Per-line checks: the first failing line produces the message.
    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        CASE WHEN i.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item not found.'
             WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
             -- (66) a BIVAC-only type (BIVAC Out) takes BIVAC items only
             WHEN @BivacOnly = 1 AND i.IsBivac = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode
                  + N' is not a BIVAC item. A ' + @TypeName + N' holds BIVAC items only.'
             WHEN iu.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN w.Id IS NULL OR w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse not found or inactive.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': quantity must be greater than zero.'
             WHEN l.UnitCost IS NOT NULL AND l.UnitCost < 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': unit cost cannot be negative.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i       ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu  ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    LEFT JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR (@BivacOnly = 1 AND i.IsBivac = 0) OR iu.Id IS NULL OR w.Id IS NULL OR w.IsActive = 0
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitCost IS NOT NULL AND l.UnitCost < 0)
    ORDER BY l.LineNumber;

    -- A parent warehouse holds no stock of its own: a line takes a warehouse at the bottom of the tree (script 70).
    IF @Msg IS NULL
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
        FROM @Lines l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
        ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;
END
GO

/* ================================================================== 3. Inventory In / Out / BIVAC Out: post */

-- Re-created (72) from the body of script 70 (Ali: 69 no branch check, each movement in the branch of its warehouse;
-- 70 the leaf check) + script 66's BIVAC line check again at posting (the item may have been un-flagged since the save).
CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE, @BranchId INT, @ReasonCode NVARCHAR(20);
        DECLARE @BivacOnly BIT, @TypeName NVARCHAR(100);   -- (66)

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @ReasonCode = r.ReasonCode,
               @BivacOnly = dt.BivacItemsOnly, @TypeName = dt.Name   -- (66)
        FROM inventory.StockDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        LEFT  JOIN inventory.StockReasons r ON r.Id = d.ReasonId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 62006, 'Document not found.', 1;
        IF @Status <> 1 THROW 62010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM inventory.StockDocumentLines WHERE DocumentId = @Id)
            THROW 62009, 'The document has no lines. Add at least one item before posting.', 1;

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 -- (66) again at posting: the item may have been un-flagged since the draft was saved
                 WHEN @BivacOnly = 1 AND i.IsBivac = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode
                      + N' is not a BIVAC item. A ' + @TypeName + N' holds BIVAC items only.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.' END
        FROM inventory.StockDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR (@BivacOnly = 1 AND i.IsBivac = 0) OR w.IsActive = 0)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

        -- A parent warehouse holds no stock of its own: a line takes a warehouse at the bottom of the tree (script 70).
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
        FROM inventory.StockDocumentLines l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

        IF @Direction = -1
        BEGIN
            UPDATE l SET UnitCost = ISNULL(inventory.fn_AverageCost(l.ItemId), 0) * l.PackingFormula
            FROM inventory.StockDocumentLines l WHERE l.DocumentId = @Id;

            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM inventory.StockDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 62007, @Msg, 1;

            UPDATE d SET TotalCost = x.Cost
            FROM inventory.StockDocuments d
            CROSS APPLY (SELECT ISNULL(SUM(LineTotal), 0) AS Cost FROM inventory.StockDocumentLines WHERE DocumentId = @Id) x
            WHERE d.Id = @Id;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        IF @Direction = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, CASE WHEN l.PackingFormula > 0 THEN l.UnitCost / l.PackingFormula ELSE l.UnitCost END, NULL
            FROM inventory.StockDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, NULL, @UserId, 0;      -- average yes, last / FOB cost no
        END

        DECLARE @MovementDate DATETIME2(3) =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
        SELECT @MovementDate, l.ItemId, l.WarehouseId, w.BranchId, @Direction * l.QuantityBase,
               CASE WHEN l.PackingFormula > 0 THEN l.UnitCost / l.PackingFormula END,
               N'Inventory', @TypeCode, @Id, l.Id, @Number, @ReasonCode, l.ExpiryDate, @UserId
        FROM inventory.StockDocumentLines l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id;

        UPDATE inventory.StockDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM inventory.StockDocumentLines WHERE DocumentId = @Id);
        INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s) written to the stock ledger', @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 4. Purchase documents: save */

-- Re-created (72) from the body of script 70 (Ali: a line's warehouse at the bottom of the tree) + script 65's refusal
-- of any type other than PO, PINV and PRET (65008): a goods receipt (GRN) lives in its own tables.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_ValidateInput
    @DocumentTypeCode   NVARCHAR(20),
    @DocumentDate       DATE,
    @ExpectedDate       DATE,
    @BranchId           INT,
    @WarehouseId        INT = NULL,
    @SupplierId         INT,
    @CurrencyId         INT,             -- NULL = supplier default currency, else base
    @RateType           TINYINT,
    @ExchangeRate       DECIMAL(18,6),   -- NULL = resolve
    @MaxDiscountPercent DECIMAL(9,4),
    @SourceDocumentId   INT,
    @Lines              purchase.tvp_PurchaseDocumentLine READONLY,
    @DocumentTypeId     INT OUTPUT,
    @StockDirection     SMALLINT OUTPUT,
    @ResolvedCurrencyId INT OUTPUT,
    @ResolvedRate       DECIMAL(18,6) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- (65) ONLY ORDERS, INVOICES AND RETURNS ARE PURCHASE DOCUMENTS. A goods receipt (GRN) is of the Purchase family
    --      too, but it lives in its own tables: a purchase.PurchaseDocuments row of type GRN would share the stock-ledger
    --      key (family Purchase + type + id) with a real goods receipt, and every query that reads a line with a source
    --      or container line as an invoice line would count it.
    IF @DocumentTypeCode IS NULL OR @DocumentTypeCode NOT IN (N'PO', N'PINV', N'PRET')
        THROW 65008, 'Only purchase orders, purchase invoices and purchase returns are saved as purchase documents. Goods receipts are made in Purchase > Goods Receipts.', 1;

    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Purchase' AND IsActive = 1;
    IF @DocumentTypeId IS NULL THROW 65008, 'Document type not found, inactive, or not a purchase document.', 1;

    IF @DocumentDate IS NULL THROW 65000, 'Document Date is required.', 1;
    /* ONE DAY OF TOLERANCE, because this compares a LOCAL date against a UTC one. The date on the
       document is the one the reader sees on their own clock; SYSUTCDATETIME() is the server's in
       UTC. East of Greenwich the two disagree for the first hours after midnight - at 00:20 in
       Beirut (UTC+3) it is still yesterday in UTC, so a document dated today was refused as being
       in the future. A day covers every offset without letting a genuinely future date through by
       more than one. */
    IF @DocumentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 65000, 'Document Date cannot be in the future.', 1;
    IF @ExpectedDate IS NOT NULL AND @ExpectedDate < @DocumentDate THROW 65000, 'Expected / due date cannot be before the Document Date.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 65008, 'Branch not found or inactive.', 1;
    IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1)
        THROW 65008, 'The header warehouse must be an active warehouse.', 1;
    IF @SupplierId IS NULL THROW 65000, 'Supplier is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsSupplier = 1 AND IsActive = 1)
        THROW 65008, 'Supplier not found, inactive, or not flagged as a supplier.', 1;

    SET @ResolvedCurrencyId = COALESCE(@CurrencyId,
                                       (SELECT DefaultCurrencyId FROM masterdata.Parties WHERE Id = @SupplierId),
                                       (SELECT TOP (1) Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1));
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @ResolvedCurrencyId AND IsActive = 1)
        THROW 65008, 'Currency not found or inactive.', 1;

    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) THROW 65000, 'Rate type must be Official, Non-official or Market.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 65000, 'Exchange rate must be greater than zero.', 1;
    SET @ResolvedRate = COALESCE(@ExchangeRate, masterdata.fn_GetRate(@ResolvedCurrencyId, @RateType, @DocumentDate));
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @ResolvedCurrencyId AND IsBaseCurrency = 1) SET @ResolvedRate = 1;
    IF @ResolvedRate IS NULL
    BEGIN
        DECLARE @Cur NVARCHAR(3) = (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @ResolvedCurrencyId);
        DECLARE @RateMsg NVARCHAR(300) = N'No ' + CASE @RateType WHEN 1 THEN N'official' WHEN 2 THEN N'non-official' ELSE N'market' END
                                       + N' exchange rate is defined for ' + @Cur + N' on or before ' + CONVERT(NVARCHAR(10), @DocumentDate, 120)
                                       + N'. Add one in Master Data > Exchange Rates or enter the rate manually.';
        THROW 65008, @RateMsg, 1;
    END

    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;
    IF @MaxDiscountPercent > 100 SET @MaxDiscountPercent = 100;

    -- Source document rules.
    IF @SourceDocumentId IS NOT NULL
    BEGIN
        DECLARE @SrcType NVARCHAR(20), @SrcStatus TINYINT, @SrcSupplier INT, @SrcBranch INT;
        SELECT @SrcType = dt.Code, @SrcStatus = d.Status, @SrcSupplier = d.SupplierId, @SrcBranch = d.BranchId
        FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceDocumentId;
        IF @SrcType IS NULL THROW 65011, 'Source document not found.', 1;
        IF (@DocumentTypeCode = N'PINV' AND @SrcType <> N'PO') OR (@DocumentTypeCode = N'PRET' AND @SrcType <> N'PINV') OR @DocumentTypeCode = N'PO'
            THROW 65011, 'A purchase invoice can only come from a purchase order and a return from a purchase invoice.', 1;
        IF @SrcStatus <> 2 THROW 65011, 'The source document must be posted (and, for an order, still open).', 1;
        IF @SrcSupplier <> @SupplierId THROW 65011, 'The supplier must be the supplier of the source document.', 1;
        IF @SrcBranch <> @BranchId THROW 65011, 'The branch must be the branch of the source document.', 1;
        IF EXISTS (SELECT 1 FROM @Lines l WHERE l.SourceLineId IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines s WHERE s.Id = l.SourceLineId AND s.DocumentId = @SourceDocumentId))
            THROW 65011, 'A line refers to a source line that does not belong to the source document.', 1;
    END

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN i.Id IS NULL THEN N'item not found.'
             WHEN i.IsActive = 0 THEN N'item ' + i.ItemCode + N' is inactive.'
             WHEN iu.Id IS NULL THEN N'the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN w.Id IS NULL OR w.IsActive = 0 THEN N'warehouse not found or inactive.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'quantity must be greater than zero.'
             WHEN l.UnitPrice IS NOT NULL AND l.UnitPrice < 0 THEN N'unit price cannot be negative.'
             WHEN l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent)
                  THEN N'discount must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(12)) + N'%.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i      ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    LEFT JOIN masterdata.Warehouses w  ON w.Id = l.WarehouseId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL OR w.Id IS NULL OR w.IsActive = 0
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitPrice IS NOT NULL AND l.UnitPrice < 0)
       OR (l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent))
    ORDER BY l.LineNumber;
    -- A parent warehouse holds no stock of its own: a line takes a warehouse at the bottom of the tree (script 70).
    IF @Msg IS NULL
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
        FROM @Lines l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
        ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 65000, @Msg, 1;
END
GO

/* ================================================================== 5. Purchase documents: post */

-- Re-created (72) from the body of script 65 (which already held 42's approval, 48's line warehouses of any branch,
-- 63's one item by mode and 65's goods receipts: see 65's header) + script 70's leaf check of the lines (65000), which
-- Ali wrote on the body of script 48. Every rule of 65 stays as it was: a supplier invoice moves no stock, the
-- matching lock, the rematch and true-up, "Receive the goods now", returns capped by what was received.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Post
    @Id         INT,
    @RowVersion   BINARY(8) = NULL,
    @UserId       INT       = NULL,
    @FromApproval BIT       = 0,     -- 1 = called by the approval
    -- (65) "Receive the goods now" (a supplier invoice only): once the invoice is posted and committed, its lines not in
    --      a container are received with a goods receipt, created and posted in a second transaction. The API passes 1
    --      only for a user who may also create and post goods receipts. A receipt that fails leaves the invoice posted
    --      and says why in @ReceiveWarning.
    @ReceiveNow         BIT           = 0,
    @GoodsReceiptId     INT           = NULL OUTPUT,
    @GoodsReceiptNumber NVARCHAR(30)  = NULL OUTPUT,
    @ReceiveWarning     NVARCHAR(700) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT @GoodsReceiptId = NULL, @GoodsReceiptNumber = NULL, @ReceiveWarning = NULL;
    -- (65) the cost of goods already received, brought to this invoice's price (usp_GoodsReceipt_TrueUpCost)
    DECLARE @CostAmount DECIMAL(18,2) = 0, @CostInventory DECIMAL(18,2) = 0, @CostCogs DECIMAL(18,2) = 0, @CostLines INT = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- (65) lock order: the goods receipt matcher first, then rows, or two postings deadlock. Only a supplier invoice or
        --      a return (their type, read without a lock: it never changes).
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                   WHERE d.Id = @Id AND dt.Code IN (N'PINV', N'PRET'))
            EXEC purchase.usp_GoodsReceipt_LockMatching;

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
        -- (65) EVERY SUPPLIER INVOICE, whatever its receipt mode: goods enter stock only through a posted goods receipt.
        --      The invoice still gets its FOB, its charges and its landed cost per line (the INVOICE COST that received
        --      goods are valued at or corrected to), and it is marked UsesGoodsReceipts = 1 when it is posted below.
        --      Returns still take their goods out at posting. (Was @ReceiveNow, now the name of the parameter.)
        DECLARE @StockAtPosting BIT = CASE WHEN @TypeCode = N'PINV' THEN 0 ELSE 1 END;

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

            -- (65) A container received with a goods receipt can be invoiced (the goods may arrive first): only a cancelled
            --      container, or one offloaded before goods receipts, is refused - and more than the loaded pieces.
            DECLARE @CtMsg NVARCHAR(400);
            SELECT TOP (1) @CtMsg = N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                    + CASE WHEN c.Status = 8 OR (c.Status IN (6, 7) AND rb.ReceivedBy = N'Offload')
                                           THEN N'the container is cancelled or was offloaded before goods receipts.'
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
            CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
            WHERE c.Status = 8 OR (c.Status IN (6, 7) AND rb.ReceivedBy = N'Offload') OR q.Here + ISNULL(o.Posted, 0) > cl.QuantityBase
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

        -- A parent warehouse holds no stock of its own: a line takes a warehouse at the bottom of the tree (script 70).
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
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
                -- (65) From an invoice that uses goods receipts, or is shipped in containers, only what was RECEIVED and not
                --      returned yet goes back (rule 23): goods received but not invoiced, or invoiced but not received, are
                --      not on the invoice line. An invoice posted with its stock before goods receipts keeps invoiced - returned.
                --      The source lines are locked until the return raises their ReturnedQuantityBase below, so what they
                --      received cannot move in between (the matching lock above keeps goods receipts out meanwhile).
                SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + CASE WHEN g.ByReceipts = 1
                                            THEN N' base units returned but only ' + CAST(CASE WHEN g.Avail > 0 THEN g.Avail ELSE 0 END AS NVARCHAR(20))
                                                 + N' were received and not returned on the invoice line.'
                                            ELSE N' base units returned but only ' + CAST(s.QuantityBase - s.ReturnedQuantityBase AS NVARCHAR(20)) + N' can still be returned from the invoice line.' END
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s WITH (UPDLOCK, HOLDLOCK) ON s.Id = x.SourceLineId
                INNER JOIN purchase.PurchaseDocuments sd    ON sd.Id = s.DocumentId
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                CROSS APPLY (SELECT ByReceipts = CASE WHEN sd.UsesGoodsReceipts = 1 OR sd.ReceiptMode = 2 THEN 1 ELSE 0 END,
                                    Avail      = CASE WHEN sd.UsesGoodsReceipts = 1 OR sd.ReceiptMode = 2 THEN s.ReceivedQuantityBase - s.ReturnedQuantityBase
                                                      ELSE s.QuantityBase - s.ReturnedQuantityBase END) g
                WHERE x.Qty > g.Avail
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
        BEGIN
            -- (65) Rule 23: from an invoice that uses goods receipts, or is shipped in containers, the goods go back at the
            --      invoice line's OWN CURRENT cost, worked out again now (a landed cost adjustment or a late container
            --      charge may have moved it since the draft): its landed cost, or for a container line its FOB + the
            --      container line's charges per piece received; for a line NOT linked whose pieces are matched to goods
            --      received in containers, those containers' charges per matched piece (as usp_PurchaseDocument_Save).
            --      The FOB is the invoice line's.
            UPDATE l
            SET UnitCostBase = CASE WHEN scl.Id IS NOT NULL THEN src.FobCostBase + ISNULL(scl.ChargesBase / NULLIF(scl.ReceivedQuantityBase, 0), 0)
                                    WHEN mc.CtPcs > 0 THEN (mc.CtPcs * src.FobCostBase + mc.CtCharges + (mc.Pcs - mc.CtPcs) * src.UnitCostBase) / mc.Pcs
                                    ELSE src.UnitCostBase END,
                FobCostBase  = src.FobCostBase
            FROM purchase.PurchaseDocumentLines l
            INNER JOIN purchase.PurchaseDocumentLines src ON src.Id = l.SourceLineId
            INNER JOIN purchase.PurchaseDocuments sd      ON sd.Id = src.DocumentId
            LEFT  JOIN logistics.ContainerLines scl       ON scl.Id = src.ContainerLineId
            OUTER APPLY (SELECT Pcs       = SUM(m.QuantityBase),
                                CtPcs     = SUM(CASE WHEN gl.ContainerLineId IS NOT NULL THEN m.QuantityBase ELSE 0 END),
                                CtCharges = SUM(CASE WHEN gl.ContainerLineId IS NOT NULL
                                                     THEN m.QuantityBase * ISNULL(mcl.ChargesBase / NULLIF(mcl.ReceivedQuantityBase, 0), 0)
                                                     ELSE 0 END)
                         FROM purchase.GoodsReceiptInvoiceMatches m
                         INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = m.GoodsReceiptLineId
                         LEFT  JOIN logistics.ContainerLines mcl  ON mcl.Id = gl.ContainerLineId
                         WHERE m.InvoiceLineId = src.Id AND src.ContainerLineId IS NULL) mc
            WHERE l.DocumentId = @Id AND (sd.UsesGoodsReceipts = 1 OR sd.ReceiptMode = 2) AND src.FobCostBase IS NOT NULL;

            UPDATE l SET UnitCostBase = ISNULL(l.UnitCostBase, ISNULL(inventory.fn_AverageCost(l.ItemId), 0))
            FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;
        END

        IF @Direction = 1 AND @StockAtPosting = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, ISNULL(l.UnitCostBase, 0), l.FobCostBase FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId, 1;
        END

        IF @Direction <> 0 AND @StockAtPosting = 1
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

            -- (65) An order closes by itself when every line is fully invoiced AND received or settled short (the goods
            --      receipts count what arrived; ReceivedQuantityBase on an order line still means invoiced).
            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @SourceId
                           AND (ReceivedQuantityBase < QuantityBase OR GoodsReceivedBase + GoodsShortBase < QuantityBase))
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 4, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, CloseReason = N'Fully invoiced and received' WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Closed', N'Closed: fully invoiced and received (' + @Number + N')', @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        -- (65) A supplier invoice is marked as using goods receipts WHEN IT IS POSTED (never as a draft): from now on its
        --      lines are matched to received pieces, and their ReceivedQuantityBase is the pieces matched to them.
        UPDATE purchase.PurchaseDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UsesGoodsReceipts = CASE WHEN @TypeCode = N'PINV' THEN 1 ELSE UsesGoodsReceipts END,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        -- (65) GOODS ALREADY RECEIVED FOLLOW THIS INVOICE'S COST. Its pieces are matched to the received pieces of its
        --      groups - each order line it invoices, and the supplier + item for lines without an order - now that it is
        --      posted (usp_GoodsReceipt_Rematch, first in first out); then every posted receipt line of those groups is
        --      brought to its target cost (usp_GoodsReceipt_TrueUpCost, cause PINV): the part still in stock to the
        --      stock value, the rest to cost of sales.
        IF @TypeCode = N'PINV'
        BEGIN
            DECLARE @Anchors purchase.tvp_GoodsReceiptAnchor;
            INSERT INTO @Anchors (Kind, PoLineId, SupplierId, ItemId)
            SELECT DISTINCT 'P', l.SourceLineId, NULL, NULL FROM purchase.PurchaseDocumentLines l
            WHERE l.DocumentId = @Id AND l.SourceLineId IS NOT NULL
            UNION
            SELECT DISTINCT 'S', NULL, @SupplierId, l.ItemId FROM purchase.PurchaseDocumentLines l
            WHERE l.DocumentId = @Id AND l.SourceLineId IS NULL;

            EXEC purchase.usp_GoodsReceipt_Rematch @Anchors;

            DECLARE @GroupLines logistics.tvp_IdList;
            INSERT INTO @GroupLines (Id) SELECT GoodsReceiptLineId FROM purchase.fn_GoodsReceipt_GroupLines(@Anchors);
            IF EXISTS (SELECT 1 FROM @GroupLines)
                EXEC purchase.usp_GoodsReceipt_TrueUpCost @GroupLines, N'PINV', @Id, @Number, @UserId,
                     @CostAmount OUTPUT, @CostInventory OUTPUT, @CostCogs OUTPUT, @CostLines OUTPUT;
        END

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id);
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', LEFT(N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 AND @StockAtPosting = 1 THEN N' written to the stock ledger'
                                       WHEN @StockAtPosting = 0 THEN N'; goods are received with goods receipts'     -- (65) every supplier invoice
                                       WHEN @PostedWithoutApproval = 1 THEN N' (approval not needed)'
                                       ELSE N' (order approved)' END
                                + CASE WHEN @TypeCode = N'PINV' THEN N'; landed charges ' + CAST((SELECT TotalChargesBase FROM purchase.PurchaseDocuments WHERE Id = @Id) AS NVARCHAR(30)) ELSE N'' END
                                + CASE WHEN @CostLines > 0 THEN N'; cost of received goods adjusted by ' + CAST(@CostAmount AS NVARCHAR(30))
                                                                + N' (stock ' + CAST(@CostInventory AS NVARCHAR(30)) + N', cost of sales ' + CAST(@CostCogs AS NVARCHAR(30)) + N')'
                                       ELSE N'' END, 500), @UserId);

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
        -- (65) + what the posting did to the cost of goods already received (0 when nothing)
        IF ISNULL(@FromApproval, 0) = 0
            SELECT @Number AS DocumentNumber, CostAdjustedBase = @CostAmount, CostAdjustedInventoryBase = @CostInventory,
                   CostAdjustedCogsBase = @CostCogs, CostAdjustedLines = @CostLines;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    /* (65) "RECEIVE THE GOODS NOW" (decision 7): the invoice is posted and committed above, whatever happens here. Its
       lines not in a container are received with ONE goods receipt (usp_GoodsReceipt_CreateFromInvoice: every line with
       something to receive, into the line's warehouse, dated like the invoice) and posted at once
       (usp_GoodsReceipt_Post), in a second transaction: all or nothing, so a refusal leaves no draft behind and
       "Receive goods..." on the invoice still offers everything. The refusal comes back in @ReceiveWarning; the
       receipt's id and number in @GoodsReceiptId / @GoodsReceiptNumber. usp_GoodsReceipt_Post returns its own
       DocumentNumber as a further result set, after the invoice's row: the receipt's outcome is read from the OUTPUT
       parameters. Inside a caller's transaction there is no second transaction to make: nothing is received. */
    IF ISNULL(@ReceiveNow, 0) = 1 AND @TypeCode = N'PINV'
    BEGIN
        DECLARE @ReceiptId INT = NULL, @ReceiptReason NVARCHAR(600) = NULL, @ReceiptDate DATE = @DocumentDate;
        IF @@TRANCOUNT > 0
            SET @ReceiptReason = N'it is made in a transaction of its own, and this posting runs inside another one';
        ELSE
        BEGIN
            BEGIN TRY
                BEGIN TRANSACTION;

                -- the matcher first, before the draft's rows are written (usp_GoodsReceipt_Post takes it again)
                EXEC purchase.usp_GoodsReceipt_LockMatching;

                DECLARE @NoLines purchase.tvp_GoodsReceiptLine;
                EXEC purchase.usp_GoodsReceipt_CreateFromInvoice @InvoiceId = @Id, @Lines = @NoLines, @DocumentDate = @ReceiptDate,
                     @UserId = @UserId, @NewId = @ReceiptId OUTPUT;
                EXEC purchase.usp_GoodsReceipt_Post @Id = @ReceiptId, @RowVersion = NULL, @UserId = @UserId;

                SELECT @GoodsReceiptId = Id, @GoodsReceiptNumber = DocumentNumber FROM purchase.GoodsReceipts WHERE Id = @ReceiptId;
                COMMIT TRANSACTION;
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
                SELECT @GoodsReceiptId = NULL, @GoodsReceiptNumber = NULL, @ReceiptReason = ERROR_MESSAGE();
            END CATCH
        END

        IF @ReceiptReason IS NOT NULL
        BEGIN
            -- "Invoice posted; the goods receipt was not: {reason}. Use Receive goods..." (one final period)
            SET @ReceiptReason = LTRIM(RTRIM(@ReceiptReason));
            IF RIGHT(@ReceiptReason, 1) = N'.' SET @ReceiptReason = LEFT(@ReceiptReason, LEN(@ReceiptReason) - 1);
            SET @ReceiveWarning = LEFT(N'Invoice posted; the goods receipt was not: ' + @ReceiptReason + N'. Use Receive goods' + NCHAR(8230), 700);
        END
    END
END
GO

/* ================================================================== 6. Excel import of documents: the rows */

-- Re-created (72) from the body of script 70 (Ali: the default warehouse of any branch but a leaf; a row naming a parent
-- is an Error) + script 66's ErrB, the BIVAC row check of a BivacItemsOnly type. The rows returned keep their columns.
CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_Validate
    @BranchId            INT,
    @DefaultWarehouseId  INT,
    @PriceListId         INT           = NULL,  -- NULL = cost mode (inventory / purchase): Unit Price column = cost, no price list checks
    @AllowPriceOverride  BIT           = 0,
    @MaxDiscountPercent  DECIMAL(9,4)  = 100,
    @Rows                sales.tvp_InvoiceImportRow READONLY,
    @CheckStock          BIT           = 0,     -- 1 = cumulative stock check per item + warehouse (outgoing documents)
    @DocumentTypeCode    NVARCHAR(20)  = NULL   -- the page's document type; rows for another type become Errors
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 61008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsActive = 1)
        THROW 61008, 'The default warehouse is not an active warehouse.', 1;
    IF masterdata.fn_Warehouse_IsLeaf(@DefaultWarehouseId) = 0
        THROW 61008, 'The default warehouse has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.', 1;
    IF @PriceListId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1)
        THROW 61008, 'Price list not found or inactive.', 1;
    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;
    SET @CheckStock = ISNULL(@CheckStock, 0);
    SET @DocumentTypeCode = NULLIF(LTRIM(RTRIM(@DocumentTypeCode)), N'');

    DECLARE @PageTypeName NVARCHAR(100), @Family NVARCHAR(20), @PageBivacOnly BIT = 0;
    IF @DocumentTypeCode IS NOT NULL
    BEGIN
        SELECT @PageTypeName = Name, @Family = Family, @PageBivacOnly = BivacItemsOnly FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode;
        IF @PageTypeName IS NULL THROW 61008, 'Document type not found.', 1;
    END
    -- Unit preference: 1 = sales unit first, 2 = purchase unit first, 0 = base unit first.
    DECLARE @UnitPref TINYINT = CASE WHEN @Family = N'Sales' OR (@Family IS NULL AND @PriceListId IS NOT NULL) THEN 1
                                     WHEN @Family = N'Purchase' THEN 2 ELSE 0 END;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    ;WITH resolved AS
    (
        SELECT r.RowNumber,
               ItemRef      = NULLIF(LTRIM(RTRIM(r.ItemRef)), N''),
               UnitName     = NULLIF(LTRIM(RTRIM(r.UnitName)), N''),
               WarehouseRef = NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N''),
               r.Quantity, r.RawQuantity, ManualPrice = r.UnitPrice, r.DiscountPercent, r.ExpiryDate, r.RawExpiryDate,
               Notes        = NULLIF(LTRIM(RTRIM(r.Notes)), N''),
               RowTypeRef   = NULLIF(LTRIM(RTRIM(r.DocumentTypeCode)), N''),
               rt.RowTypeCode, rt.RowTypeName, rt.RowTypeBivacOnly,
               it.ItemId, it.ItemCode, it.ItemName, it.ItemActive, it.BarcodeUnitId, it.ItemIsBivac,
               u.ItemUnitId, u.UnitTypeName, u.PackingFormula,
               w.WarehouseId, w.WarehouseCode, w.WarehouseName, w.WarehouseActive, w.WarehouseBranchId,
               pr.BranchPrice, pr.AllBranchesPrice
        FROM @Rows r
        OUTER APPLY
        (
            SELECT TOP (1) dt.Code AS RowTypeCode, dt.Name AS RowTypeName, dt.BivacItemsOnly AS RowTypeBivacOnly
            FROM inventory.DocumentTypes dt
            WHERE NULLIF(LTRIM(RTRIM(r.DocumentTypeCode)), N'') IS NOT NULL
              AND (dt.Code = LTRIM(RTRIM(r.DocumentTypeCode)) OR dt.Name = LTRIM(RTRIM(r.DocumentTypeCode)))
            ORDER BY CASE WHEN dt.Code = LTRIM(RTRIM(r.DocumentTypeCode)) THEN 0 ELSE 1 END
        ) rt
        OUTER APPLY
        (
            SELECT TOP (1) i.Id AS ItemId, i.ItemCode, i.ItemName, i.IsActive AS ItemActive, bu.Id AS BarcodeUnitId, i.IsBivac AS ItemIsBivac
            FROM inventory.Items i
            LEFT JOIN inventory.ItemUnits bu ON bu.ItemId = i.Id AND bu.Barcode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'')
            WHERE i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') OR bu.Id IS NOT NULL
            ORDER BY CASE WHEN i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') THEN 0 ELSE 1 END
        ) it
        OUTER APPLY
        (
            SELECT TOP (1) iu.Id AS ItemUnitId, t.UnitTypeName, iu.PackingFormula
            FROM inventory.ItemUnits iu
            INNER JOIN masterdata.UnitTypes t ON t.Id = iu.UnitTypeId
            WHERE iu.ItemId = it.ItemId
              AND (   (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NOT NULL
                       AND (t.UnitTypeName = LTRIM(RTRIM(r.UnitName)) OR iu.SkuCode = LTRIM(RTRIM(r.UnitName))))
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NOT NULL AND iu.Id = it.BarcodeUnitId)
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NULL))
            ORDER BY CASE @UnitPref WHEN 1 THEN CASE WHEN iu.IsSalesUnit = 1 THEN 0 ELSE 1 END
                                    WHEN 2 THEN CASE WHEN iu.IsPurchaseUnit = 1 THEN 0 ELSE 1 END
                                    ELSE CASE WHEN iu.IsBaseUnit = 1 THEN 0 ELSE 1 END END,
                     iu.IsBaseUnit DESC, iu.PackingFormula
        ) u
        OUTER APPLY
        (
            SELECT TOP (1) wh.Id AS WarehouseId, wh.WarehouseCode, wh.WarehouseName, wh.IsActive AS WarehouseActive, wh.BranchId AS WarehouseBranchId
            FROM masterdata.Warehouses wh
            WHERE (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NOT NULL
                   AND (wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) OR wh.WarehouseName = LTRIM(RTRIM(r.WarehouseRef))))
               OR (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NULL AND wh.Id = @DefaultWarehouseId)
            ORDER BY CASE WHEN wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) THEN 0 ELSE 1 END
        ) w
        OUTER APPLY
        (
            SELECT BranchPrice      = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId = @BranchId AND IsActive = 1),
                   AllBranchesPrice = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId IS NULL AND IsActive = 1)
        ) pr
    ),
    stocked AS
    (
        SELECT x.*,
               QtyBase    = CASE WHEN x.ItemUnitId IS NOT NULL AND x.Quantity IS NOT NULL AND x.Quantity > 0 AND x.Quantity = FLOOR(x.Quantity)
                                 THEN CAST(x.Quantity AS INT) * x.PackingFormula ELSE 0 END,
               OnHandBase = CASE WHEN x.ItemId IS NOT NULL AND x.WarehouseId IS NOT NULL THEN inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) END,
               AllowOos   = CASE WHEN x.WarehouseId IS NOT NULL THEN (SELECT p.Allowed FROM sales.fn_OutOfStockPolicy(x.WarehouseId) p) END
        FROM resolved x
    ),
    running AS
    (
        SELECT s.*,
               RequiredBase = SUM(s.QtyBase) OVER (PARTITION BY s.ItemId, s.WarehouseId ORDER BY s.RowNumber ROWS UNBOUNDED PRECEDING),
               EarlierRows  = STUFF((SELECT N', ' + CAST(s2.RowNumber AS NVARCHAR(10))
                                     FROM stocked s2
                                     WHERE s2.ItemId = s.ItemId AND s2.WarehouseId = s.WarehouseId AND s2.QtyBase > 0 AND s2.RowNumber < s.RowNumber
                                     ORDER BY s2.RowNumber FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N'')
        FROM stocked s
    ),
    judged AS
    (
        SELECT x.*,
               SystemPrice = COALESCE(x.BranchPrice, x.AllBranchesPrice),
               EffectiveDiscount = ISNULL(x.DiscountPercent, 0),
               Err0 = CASE WHEN x.RowTypeRef IS NOT NULL AND x.RowTypeCode IS NULL THEN N'Document Type ''' + x.RowTypeRef + N''' does not exist.'
                           WHEN x.RowTypeCode IS NOT NULL AND @DocumentTypeCode IS NOT NULL AND x.RowTypeCode <> @DocumentTypeCode
                                THEN N'This row is for ' + x.RowTypeName + N' (' + x.RowTypeCode + N'), not for ' + @PageTypeName + N'.' END,
               Err1 = CASE WHEN x.ItemRef IS NULL THEN N'Item Code / Barcode is required.'
                           WHEN x.ItemId IS NULL THEN N'Item Code ' + x.ItemRef + N' does not exist.'
                           WHEN x.ItemActive = 0 THEN N'Item ' + x.ItemCode + N' is inactive.' END,
               -- (66) a BIVAC-only type (the row's own, else the page's) takes BIVAC items only
               ErrB = CASE WHEN x.ItemId IS NOT NULL AND x.ItemIsBivac = 0
                            AND CASE WHEN x.RowTypeCode IS NOT NULL THEN x.RowTypeBivacOnly ELSE @PageBivacOnly END = 1
                                THEN x.ItemCode + N' is not a BIVAC item.' END,
               Err2 = CASE WHEN x.Quantity IS NULL AND x.RawQuantity IS NOT NULL THEN N'Quantity ''' + x.RawQuantity + N''' is not a number.'
                           WHEN x.Quantity IS NULL OR x.Quantity <= 0 THEN N'Quantity must be greater than zero.'
                           WHEN x.Quantity <> FLOOR(x.Quantity) THEN N'Quantity must be a whole number of pieces.' END,
               Err3 = CASE WHEN x.ItemId IS NOT NULL AND x.UnitName IS NOT NULL AND x.ItemUnitId IS NULL
                                THEN N'Unit ''' + x.UnitName + N''' is not configured for Item ' + x.ItemCode + N'.'
                           WHEN x.ItemId IS NOT NULL AND x.ItemUnitId IS NULL THEN N'Item ' + x.ItemCode + N' has no units configured.' END,
               Err4 = CASE WHEN x.WarehouseRef IS NOT NULL AND x.WarehouseId IS NULL THEN N'Warehouse ' + x.WarehouseRef + N' does not exist.'
                           WHEN x.WarehouseActive = 0 THEN N'Warehouse ' + x.WarehouseCode + N' is inactive.'
                           WHEN masterdata.fn_Warehouse_IsLeaf(x.WarehouseId) = 0 THEN N'Warehouse ' + x.WarehouseCode + N' has warehouses under it: choose one of those.' END,
               Err5 = CASE WHEN @PriceListId IS NOT NULL AND x.ItemUnitId IS NOT NULL
                            AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NULL
                            AND NOT (x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1)
                                THEN N'No selling price was found for Item ' + x.ItemCode + N', Unit ' + x.UnitTypeName + N', and the selected Price List.'
                           WHEN x.ManualPrice IS NOT NULL AND x.ManualPrice < 0 THEN N'Unit Price cannot be negative.' END,
               Err6 = CASE WHEN ISNULL(x.DiscountPercent, 0) < 0 OR ISNULL(x.DiscountPercent, 0) > @MaxDiscountPercent
                                THEN N'Discount % must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(20)) + N'.' END,
               Err7 = CASE WHEN x.ExpiryDate IS NULL AND x.RawExpiryDate IS NOT NULL THEN N'Expiry Date ''' + x.RawExpiryDate + N''' is not a valid date.' END,
               Err8 = CASE WHEN @CheckStock = 1 AND NOT (@DocumentTypeCode = N'SINV' AND ISNULL(x.AllowOos, 0) = 1) AND x.QtyBase > 0 AND x.WarehouseId IS NOT NULL AND x.RequiredBase > ISNULL(x.OnHandBase, 0)
                                THEN N'Insufficient stock for ' + x.ItemCode + N' in ' + x.WarehouseCode + N': available ' + CAST(ISNULL(x.OnHandBase, 0) AS NVARCHAR(20))
                                     + N', required ' + CAST(x.RequiredBase AS NVARCHAR(20))
                                     + CASE WHEN x.EarlierRows IS NULL THEN N'' ELSE N' (with rows ' + x.EarlierRows + N')' END + N'.' END,
               Warn4 = CASE WHEN @CheckStock = 1 AND @DocumentTypeCode = N'SINV' AND ISNULL(x.AllowOos, 0) = 1 AND x.QtyBase > 0 AND x.WarehouseId IS NOT NULL
                             AND x.RequiredBase > ISNULL(x.OnHandBase, 0)
                                THEN N'Out of stock: ' + x.ItemCode + N' in ' + x.WarehouseCode + N' - available ' + CAST(ISNULL(x.OnHandBase, 0) AS NVARCHAR(20))
                                     + N', selling ' + CAST(x.RequiredBase AS NVARCHAR(20)) + N'. Posting will ask you to confirm.' END,
               Warn1 = CASE WHEN @PriceListId IS NOT NULL AND x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 0 AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NOT NULL
                                THEN N'Manual price ignored - system price ' + CAST(COALESCE(x.BranchPrice, x.AllBranchesPrice) AS NVARCHAR(30)) + N' used (no price override permission).' END,
               Warn2 = CASE WHEN x.ExpiryDate IS NOT NULL AND x.ExpiryDate < @Today THEN N'Expiry date is in the past.' END,
               Warn3 = CASE WHEN @UnitPref = 1 AND x.UnitName IS NULL AND x.BarcodeUnitId IS NULL AND x.ItemUnitId IS NOT NULL
                             AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits s WHERE s.ItemId = x.ItemId AND s.IsSalesUnit = 1)
                                THEN N'No sales unit is flagged for this item - the base unit was used.'
                            WHEN @UnitPref = 2 AND x.UnitName IS NULL AND x.BarcodeUnitId IS NULL AND x.ItemUnitId IS NOT NULL
                             AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits s WHERE s.ItemId = x.ItemId AND s.IsPurchaseUnit = 1)
                                THEN N'No purchase unit is flagged for this item - the base unit was used.' END
        FROM running x
    )
    SELECT j.RowNumber,
           Status  = CASE WHEN COALESCE(j.Err0, j.Err1, j.ErrB, j.Err2, j.Err3, j.Err4, j.Err5, j.Err6, j.Err7, j.Err8) IS NOT NULL THEN N'Error'
                          WHEN COALESCE(j.Warn1, j.Warn2, j.Warn3, j.Warn4) IS NOT NULL THEN N'Warning'
                          ELSE N'Valid' END,
           Message = NULLIF(LTRIM(CONCAT(ISNULL(j.Err0 + N' ', N''), ISNULL(j.Err1 + N' ', N''), ISNULL(j.ErrB + N' ', N''), ISNULL(j.Err2 + N' ', N''), ISNULL(j.Err3 + N' ', N''), ISNULL(j.Err4 + N' ', N''),
                                         ISNULL(j.Err5 + N' ', N''), ISNULL(j.Err6 + N' ', N''), ISNULL(j.Err7 + N' ', N''), ISNULL(j.Err8 + N' ', N''),
                                         ISNULL(j.Warn1 + N' ', N''), ISNULL(j.Warn2 + N' ', N''), ISNULL(j.Warn3 + N' ', N''), ISNULL(j.Warn4, N''))), N''),
           RowDocumentTypeCode = ISNULL(j.RowTypeCode, @DocumentTypeCode),
           j.ItemRef, j.ItemId, j.ItemCode, j.ItemName,
           j.ItemUnitId, j.UnitTypeName, j.PackingFormula,
           j.WarehouseId, j.WarehouseCode, j.WarehouseName,
           Quantity    = CASE WHEN j.Quantity IS NOT NULL AND j.Quantity > 0 AND j.Quantity = FLOOR(j.Quantity) THEN CAST(j.Quantity AS INT) END,
           UnitPrice   = CASE WHEN @PriceListId IS NULL THEN j.ManualPrice
                              WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN j.ManualPrice
                              ELSE j.SystemPrice END,
           PriceSource = CASE WHEN @PriceListId IS NULL THEN CASE WHEN j.ManualPrice IS NOT NULL THEN N'Manual' END
                              WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN N'Manual'
                              WHEN j.BranchPrice IS NOT NULL THEN N'Branch'
                              WHEN j.AllBranchesPrice IS NOT NULL THEN N'AllBranches' END,
           ManualPrice = j.ManualPrice,
           DiscountPercent = j.EffectiveDiscount,
           j.ExpiryDate, j.Notes,
           j.OnHandBase, j.RequiredBase
    FROM judged j
    ORDER BY j.RowNumber;
END
GO

/* ================================================================== 7. The container Offload stays retired */

-- Re-created (72) from the body of script 65, unchanged: a refusal. Script 70 re-created the old offload (the body of
-- script 27 + "the offloading warehouse must be a leaf"); containers are received with a goods receipt
-- (purchase.usp_GoodsReceipt_CreateForContainer, then _Post), whose "Receive into" now follows that rule (sections 8
-- and 9). The parameters stay, so an old caller gets the reason rather than an error about the call.
CREATE OR ALTER PROCEDURE logistics.usp_Container_Offload
    @Id            INT,
    @Lines         logistics.tvp_ContainerReceipt READONLY,   -- (65) ignored
    @OffloadedDate DATE      = NULL,                          -- (65) ignored
    @WarehouseId   INT       = NULL,                          -- (65) ignored
    @RowVersion    BINARY(8) = NULL,                          -- (65) ignored
    @UserId        INT       = NULL                           -- (65) ignored
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Msg NVARCHAR(200) = N'Containers are received with a goods receipt now. Use Receive goods' + NCHAR(8230) + N' on the container.';
    THROW 69010, @Msg, 1;
END
GO

/* ================================================================== 8. Goods receipt: save */

-- Re-created (72) from the body of script 64: + the warehouse at the bottom of the tree (script 70) - a container's
-- "Receive into" (still of the container's branch), the "Receive into" of the other receipts (the lines' default) and
-- each local line's warehouse. Nothing else changes.
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_Save
    @Id                INT            = NULL,
    @SourceKind        NVARCHAR(10)   = NULL,    -- new receipt: Container | Order | Invoice | Manual; NULL = from the ids
    @DocumentDate      DATE           = NULL,    -- date received; NULL = today (UTC)
    @BranchId          INT            = NULL,    -- Manual (else the warehouse's); several orders; ignored otherwise
    @WarehouseId       INT            = NULL,    -- "Receive into": a container's lines, the default of local lines
    @SupplierId        INT            = NULL,    -- Manual: required; otherwise checked against the source
    @ContainerId       INT            = NULL,
    @PurchaseOrderId   INT            = NULL,    -- informative: taken from the lines
    @PurchaseInvoiceId INT            = NULL,
    @SupplierReference NVARCHAR(100)  = NULL,    -- delivery note no.
    @Notes             NVARCHAR(1000) = NULL,
    @Lines             purchase.tvp_GoodsReceiptLine READONLY,
    @RowVersion        BINARY(8)      = NULL,
    @UserId            INT            = NULL,
    @NewId             INT            = NULL OUTPUT,
    @MovementId        INT            = NULL     -- new container receipt: the completed Delivery movement that made it
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SourceKind = NULLIF(LTRIM(RTRIM(@SourceKind)), N'');
    SET @SupplierReference = NULLIF(LTRIM(RTRIM(@SupplierReference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Msg NVARCHAR(400), @TypeId INT, @IsAuto BIT = 0,
            @OldStatus TINYINT, @OldSource NVARCHAR(10), @OldContainer INT, @OldInvoice INT, @OldMovement INT, @OldBranch INT,
            @Ref NVARCHAR(30), @CtStatus TINYINT, @CtBranch INT, @MovNo NVARCHAR(30),
            @InvNo NVARCHAR(30), @InvStatus TINYINT, @InvBranch INT, @InvSupplier INT, @InvOld BIT, @SourceText NVARCHAR(300);

    /* ---------- 1. The receipt and its source */
    IF @Id IS NOT NULL
    BEGIN
        SELECT @OldStatus = Status, @OldSource = SourceKind, @OldContainer = ContainerId, @OldInvoice = PurchaseInvoiceId,
               @OldMovement = MovementId, @OldBranch = BranchId, @IsAuto = IsAuto
        FROM purchase.GoodsReceipts WHERE Id = @Id;
        IF @OldStatus IS NULL THROW 63006, 'Goods receipt not found.', 1;
        IF @OldStatus <> 1 THROW 63005, 'Only a draft goods receipt can be changed or deleted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceipts WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 63004, 'This goods receipt was modified by another user. Reload the page and try again.', 1;
        IF (@SourceKind IS NOT NULL AND @SourceKind <> @OldSource)
           OR (@ContainerId IS NOT NULL AND @ContainerId <> ISNULL(@OldContainer, -1))
           OR (@PurchaseInvoiceId IS NOT NULL AND @PurchaseInvoiceId <> ISNULL(@OldInvoice, -1))
           OR (@MovementId IS NOT NULL AND @MovementId <> ISNULL(@OldMovement, -1))
            THROW 63000, 'The source of a goods receipt cannot be changed: delete the draft and create another one.', 1;
        SELECT @SourceKind = @OldSource, @ContainerId = @OldContainer, @PurchaseInvoiceId = @OldInvoice, @MovementId = @OldMovement;
    END
    ELSE
    BEGIN
        SET @SourceKind = COALESCE(@SourceKind,
                                   CASE WHEN @ContainerId IS NOT NULL THEN N'Container'
                                        WHEN @PurchaseInvoiceId IS NOT NULL THEN N'Invoice'
                                        WHEN @PurchaseOrderId IS NOT NULL OR EXISTS (SELECT 1 FROM @Lines WHERE PoLineId IS NOT NULL) THEN N'Order'
                                        ELSE N'Manual' END);
        IF @SourceKind NOT IN (N'Container', N'Order', N'Invoice', N'Manual')
            THROW 63000, 'The source of a goods receipt is a container, an order, an invoice, or none (Manual).', 1;
        IF @SourceKind = N'Container' AND @ContainerId IS NULL THROW 63000, 'Choose the container.', 1;
        IF @SourceKind = N'Invoice' AND @PurchaseInvoiceId IS NULL THROW 63000, 'Choose the purchase invoice.', 1;
        IF (@SourceKind <> N'Container' AND (@ContainerId IS NOT NULL OR @MovementId IS NOT NULL))
           OR (@SourceKind <> N'Invoice' AND @PurchaseInvoiceId IS NOT NULL)
           OR (@SourceKind = N'Manual' AND @PurchaseOrderId IS NOT NULL)
            THROW 63000, 'A goods receipt has one source: a container, an order, an invoice, or none (Manual).', 1;
        SET @IsAuto = CASE WHEN @MovementId IS NOT NULL THEN 1 ELSE 0 END;
    END

    IF @DocumentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 63000, 'The date received cannot be in the future.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Lines) THROW 63009, 'The goods receipt has no lines.', 1;
    SET @TypeId = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'GRN');   -- an inactive type still takes drafts
    IF @TypeId IS NULL THROW 63010, 'The document type GRN is missing: restart the API so that script 64 creates it.', 1;

    /* ---------- 2. The lines, as given */
    DECLARE @L TABLE
    (
        LineNumber           INT           NOT NULL PRIMARY KEY,
        ItemId               INT           NOT NULL,
        ItemUnitId           INT           NOT NULL,
        Quantity             INT           NOT NULL,
        PackingFormula       INT           NULL,      -- NULL: the unit is not one of the item's
        IsBaseUnit           BIT           NULL,
        QuantityBase         INT           NULL,
        WarehouseId          INT           NULL,
        PoLineId             INT           NULL,
        PurchaseOrderId      INT           NULL,
        InvoiceLineId        INT           NULL,
        ContainerLineId      INT           NULL,
        ExpectedQuantityBase INT           NULL,
        VarianceReasonCode   NVARCHAR(20)  NULL,
        VarianceReason       NVARCHAR(300) NULL,
        CloseShort           BIT           NOT NULL,
        ManualUnitCostBase   DECIMAL(18,6) NULL,
        ExpiryDate           DATE          NULL,
        Notes                NVARCHAR(300) NULL,
        SupplierId           INT           NULL
    );
    INSERT INTO @L (LineNumber, ItemId, ItemUnitId, Quantity, PackingFormula, IsBaseUnit, QuantityBase, WarehouseId, PoLineId,
                    InvoiceLineId, ContainerLineId, ExpectedQuantityBase, VarianceReasonCode, VarianceReason, CloseShort,
                    ManualUnitCostBase, ExpiryDate, Notes)
    SELECT l.LineNumber, l.ItemId, l.ItemUnitId, l.Quantity, iu.PackingFormula, iu.IsBaseUnit,
           CASE WHEN iu.Id IS NOT NULL THEN l.Quantity * iu.PackingFormula END,
           l.WarehouseId, l.PoLineId, l.InvoiceLineId, l.ContainerLineId, l.ExpectedQuantityBase,
           NULLIF(UPPER(LTRIM(RTRIM(l.VarianceReasonCode))), N''), NULLIF(LTRIM(RTRIM(l.VarianceReason)), N''),
           ISNULL(l.CloseShort, 0), l.ManualUnitCostBase, l.ExpiryDate, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
    FROM @Lines l
    LEFT JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId;

    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN i.Id IS NULL THEN N'item not found.'
             WHEN l.PackingFormula IS NULL THEN N'the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN l.Quantity < 0 THEN N'the received quantity cannot be negative.'
             WHEN l.VarianceReasonCode NOT IN (N'SHORT', N'DAMAGED', N'MISSING', N'LOADCOUNT', N'OTHER')
                 THEN N'the reason is Short-shipped (SHORT), Damaged (DAMAGED), Missing (MISSING), Wrongly counted at loading (LOADCOUNT) or Other (OTHER).'
             WHEN l.ManualUnitCostBase < 0 THEN N'the unit cost cannot be negative.'
             WHEN l.ContainerLineId IS NOT NULL AND @SourceKind <> N'Container' THEN N'only the goods receipt of a container has container lines.'
             WHEN l.InvoiceLineId IS NOT NULL AND @SourceKind <> N'Invoice' THEN N'only the goods receipt of an invoice has invoice lines.'
             ELSE N'a goods receipt without an order has no order lines.' END
    FROM @L l
    LEFT JOIN inventory.Items i ON i.Id = l.ItemId
    WHERE i.Id IS NULL OR l.PackingFormula IS NULL OR l.Quantity < 0
       OR (l.VarianceReasonCode IS NOT NULL AND l.VarianceReasonCode NOT IN (N'SHORT', N'DAMAGED', N'MISSING', N'LOADCOUNT', N'OTHER'))
       OR l.ManualUnitCostBase < 0
       OR (l.ContainerLineId IS NOT NULL AND @SourceKind <> N'Container')
       OR (l.InvoiceLineId IS NOT NULL AND @SourceKind <> N'Invoice')
       OR (l.PoLineId IS NOT NULL AND @SourceKind = N'Manual')
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

    /* ---------- 3. By source */
    IF @SourceKind = N'Container'
    BEGIN
        SELECT @Ref = ContainerRef, @CtStatus = Status, @CtBranch = BranchId FROM logistics.Containers WHERE Id = @ContainerId;
        IF @Ref IS NULL THROW 63006, 'Container not found.', 1;
        IF @Id IS NULL AND @CtStatus NOT BETWEEN 2 AND 5
            THROW 63010, 'Only a confirmed container that is not received yet can be received.', 1;
        IF @Id IS NULL AND @MovementId IS NOT NULL
        BEGIN
            SELECT @MovNo = m.MovementNo FROM logistics.Movements m WHERE m.Id = @MovementId;
            IF NOT EXISTS (SELECT 1 FROM logistics.Movements m
                           INNER JOIN masterdata.MovementTypes mt     ON mt.Id = m.MovementTypeId AND mt.Stage = N'Delivery'
                           INNER JOIN logistics.MovementContainers mc ON mc.MovementId = m.Id AND mc.ContainerId = @ContainerId
                           WHERE m.Id = @MovementId AND m.Status = 3)
            BEGIN
                SET @Msg = N'Movement ' + ISNULL(@MovNo, N'#' + CAST(@MovementId AS NVARCHAR(10)))
                         + N' is not a completed Delivery movement of container ' + @Ref + N'.';
                THROW 63010, @Msg, 1;
            END
        END
        IF @MovementId IS NOT NULL AND @MovNo IS NULL SET @MovNo = (SELECT MovementNo FROM logistics.Movements WHERE Id = @MovementId);
        SET @BranchId = @CtBranch;
        IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @CtBranch)
        BEGIN
            SET @Msg = N'The warehouse ' + ISNULL((SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId), N'#' + CAST(@WarehouseId AS NVARCHAR(10)))
                     + N' is inactive or does not belong to the branch of container ' + @Ref + N'.';
            THROW 63000, @Msg, 1;
        END
        -- (72) AT THE BOTTOM OF THE TREE as well (script 70, which asked it of the offloading warehouse): a warehouse with
        --      warehouses under it is a group, not a place that holds stock. It stays in the container's branch, above.
        IF @WarehouseId IS NOT NULL AND masterdata.fn_Warehouse_IsLeaf(@WarehouseId) = 0
        BEGIN
            SET @Msg = N'The warehouse ' + (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId)
                     + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.';
            THROW 63000, @Msg, 1;
        END
        SELECT @Msg = N'The goods cannot be received before ' + d.MovementNo + N' reached ' + d.PlaceName + N' on '
                      + CONVERT(NVARCHAR(10), d.EndDate, 23) + N'.'
        FROM logistics.fn_Container_LastDelivery(@ContainerId) d
        WHERE @DocumentDate < d.EndDate;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        -- the lines are the container's lines, each once, in pieces, never above the loaded pieces
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): ' +
            CASE WHEN cl.Id IS NULL THEN N'it is not a line of container ' + @Ref + N'.'
                 WHEN (SELECT COUNT(*) FROM @L d WHERE d.ContainerLineId = l.ContainerLineId) > 1
                     THEN N'line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' of container ' + @Ref + N' is on this goods receipt twice.'
                 WHEN cl.ItemId <> l.ItemId THEN N'the item differs from the container line.'
                 WHEN l.IsBaseUnit = 0 THEN N'a container line is received in pieces (the base unit).'
                 ELSE N'received ' + CAST(l.QuantityBase AS NVARCHAR(20)) + N' but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' were loaded.' END
        FROM @L l
        INNER JOIN inventory.Items i           ON i.Id = l.ItemId
        LEFT  JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId AND cl.ContainerId = @ContainerId
        WHERE cl.Id IS NULL OR cl.ItemId <> l.ItemId OR l.IsBaseUnit = 0 OR l.QuantityBase > cl.QuantityBase
           OR (SELECT COUNT(*) FROM @L d WHERE d.ContainerLineId = l.ContainerLineId) > 1
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        SELECT TOP (1) @Msg = N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' of container ' + @Ref + N' (' + i.ItemCode
                              + N') is missing: a container is received with all its lines.'
        FROM logistics.ContainerLines cl
        INNER JOIN inventory.Items i ON i.Id = cl.ItemId
        WHERE cl.ContainerId = @ContainerId AND NOT EXISTS (SELECT 1 FROM @L l WHERE l.ContainerLineId = cl.Id)
        ORDER BY cl.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        -- THE ITEM IS ACTIVE (rule 12), as on the lines of the other sources (section 4), with their sentence: a draft
        -- that Post would refuse is not made. (CreateForContainer, silent for a Delivery, skips such a container.)
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): item ' + i.ItemCode + N' is inactive.'
        FROM @L l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        WHERE i.IsActive = 0
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode
                              + N'): choose a reason when the received quantity differs from the loaded quantity.'
        FROM @L l
        INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
        INNER JOIN inventory.Items i           ON i.Id = l.ItemId
        WHERE l.QuantityBase <> cl.QuantityBase AND l.VarianceReasonCode IS NULL
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        -- the links come from the container line: its order line, order and supplier; expected = loaded; one warehouse
        UPDATE l
        SET PoLineId = cl.PoLineId, PurchaseOrderId = cl.PurchaseOrderId, SupplierId = po.SupplierId,
            ExpectedQuantityBase = cl.QuantityBase, WarehouseId = @WarehouseId, CloseShort = 0, ManualUnitCostBase = NULL,
            ExpiryDate = COALESCE(l.ExpiryDate, pol.ExpiryDate)
        FROM @L l
        INNER JOIN logistics.ContainerLines cl        ON cl.Id = l.ContainerLineId
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
        INNER JOIN purchase.PurchaseDocuments po      ON po.Id = cl.PurchaseOrderId;

        SET @SupplierId = CASE WHEN (SELECT COUNT(DISTINCT SupplierId) FROM @L) = 1 THEN (SELECT MIN(SupplierId) FROM @L) END;
        SET @PurchaseOrderId = CASE WHEN (SELECT COUNT(DISTINCT PurchaseOrderId) FROM @L) = 1 THEN (SELECT MIN(PurchaseOrderId) FROM @L) END;
        SET @SourceText = N'Draft from container ' + @Ref
                        + ISNULL(N', created automatically when ' + @MovNo + N' was completed', N'');
    END
    ELSE IF @SourceKind = N'Order'
    BEGIN
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN l.PoLineId IS NULL THEN N'choose a line of a purchase order.'
                 WHEN pol.Id IS NULL OR dt.Id IS NULL THEN N'the order line was not found.'
                 WHEN (SELECT COUNT(*) FROM @L d WHERE d.PoLineId = l.PoLineId) > 1
                     THEN N'line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' of order ' + ISNULL(po.DocumentNumber, N'#' + CAST(po.Id AS NVARCHAR(10)))
                          + N' is on this goods receipt twice.'
                 ELSE N'the item differs from the order line.' END
        FROM @L l
        LEFT JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        LEFT JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId
        LEFT JOIN inventory.DocumentTypes dt         ON dt.Id = po.DocumentTypeId AND dt.Code = N'PO'
        WHERE l.PoLineId IS NULL OR pol.Id IS NULL OR dt.Id IS NULL OR pol.ItemId <> l.ItemId
           OR (SELECT COUNT(*) FROM @L d WHERE d.PoLineId = l.PoLineId) > 1
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        SELECT TOP (1) @Msg = CASE WHEN po.Status = 3 THEN N'The purchase order ' + ISNULL(po.DocumentNumber, N'#' + CAST(po.Id AS NVARCHAR(10))) + N' is cancelled.'
                                   ELSE N'Only an approved order can be received.' END
        FROM @L l
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        INNER JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId
        WHERE po.Status NOT IN (2, 4)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63010, @Msg, 1;

        UPDATE l
        SET PurchaseOrderId = pol.DocumentId, SupplierId = po.SupplierId, ManualUnitCostBase = NULL,
            WarehouseId = COALESCE(l.WarehouseId, @WarehouseId, pol.WarehouseId),
            ExpiryDate = COALESCE(l.ExpiryDate, pol.ExpiryDate)
        FROM @L l
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        INNER JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId;

        IF (SELECT COUNT(DISTINCT SupplierId) FROM @L) > 1
            THROW 63000, 'A goods receipt from purchase orders holds the orders of one supplier.', 1;
        IF @SupplierId IS NOT NULL AND @SupplierId <> (SELECT MIN(SupplierId) FROM @L)
            THROW 63000, 'The supplier must be the supplier of the purchase order.', 1;
        SET @SupplierId = (SELECT MIN(SupplierId) FROM @L);
        SET @PurchaseOrderId = CASE WHEN (SELECT COUNT(DISTINCT PurchaseOrderId) FROM @L) = 1 THEN (SELECT MIN(PurchaseOrderId) FROM @L) END;
        -- numbered in the order's branch; a receipt of several orders keeps the branch given (or the first line's order's)
        SET @BranchId = CASE WHEN @PurchaseOrderId IS NOT NULL THEN (SELECT BranchId FROM purchase.PurchaseDocuments WHERE Id = @PurchaseOrderId)
                             ELSE COALESCE(@BranchId, @OldBranch,
                                           (SELECT TOP (1) po.BranchId FROM @L l INNER JOIN purchase.PurchaseDocuments po ON po.Id = l.PurchaseOrderId
                                            ORDER BY l.LineNumber)) END;
        SET @SourceText = N'Draft from order ' + ISNULL((SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @PurchaseOrderId), N'(several orders)');
    END
    ELSE IF @SourceKind = N'Invoice'
    BEGIN
        SELECT @InvNo = d.DocumentNumber, @InvStatus = d.Status, @InvBranch = d.BranchId, @InvSupplier = d.SupplierId,
               @InvOld = CASE WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 THEN 1 ELSE 0 END
        FROM purchase.PurchaseDocuments d
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
        WHERE d.Id = @PurchaseInvoiceId;
        IF @InvStatus IS NULL THROW 63006, 'Purchase invoice not found.', 1;
        IF @InvStatus = 3 THROW 63010, 'The purchase invoice is cancelled.', 1;
        IF @InvStatus NOT IN (2, 4) THROW 63010, 'Post the invoice first: goods are received against a posted invoice, or from the order.', 1;
        IF @InvOld = 1 THROW 63010, 'Posted before goods receipts: its stock entered when it was posted (or when its container was offloaded).', 1;

        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN pil.Id IS NULL THEN N'choose a line of invoice ' + ISNULL(@InvNo, N'#' + CAST(@PurchaseInvoiceId AS NVARCHAR(10))) + N'.'
                 WHEN pil.ContainerLineId IS NOT NULL
                     THEN N'this invoice line travels in container ' + ISNULL(c.ContainerRef, N'?') + N': it is received with its container.'
                 WHEN (SELECT COUNT(*) FROM @L d WHERE d.InvoiceLineId = l.InvoiceLineId) > 1
                     THEN N'line ' + CAST(pil.LineNumber AS NVARCHAR(10)) + N' of the invoice is on this goods receipt twice.'
                 WHEN pil.ItemId <> l.ItemId THEN N'the item differs from the invoice line.'
                 ELSE N'the order line differs from the invoice line.' END
        FROM @L l
        LEFT JOIN purchase.PurchaseDocumentLines pil ON pil.Id = l.InvoiceLineId AND pil.DocumentId = @PurchaseInvoiceId
        LEFT JOIN logistics.ContainerLines cl        ON cl.Id = pil.ContainerLineId
        LEFT JOIN logistics.Containers c             ON c.Id = cl.ContainerId
        WHERE pil.Id IS NULL OR pil.ContainerLineId IS NOT NULL OR pil.ItemId <> l.ItemId
           OR (SELECT COUNT(*) FROM @L d WHERE d.InvoiceLineId = l.InvoiceLineId) > 1
           OR (l.PoLineId IS NOT NULL AND l.PoLineId <> ISNULL(pil.SourceLineId, -1))
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        UPDATE l
        SET PoLineId = pil.SourceLineId, PurchaseOrderId = pol.DocumentId, SupplierId = @InvSupplier, ManualUnitCostBase = NULL,
            WarehouseId = COALESCE(l.WarehouseId, @WarehouseId, pil.WarehouseId),
            ExpiryDate = COALESCE(l.ExpiryDate, pil.ExpiryDate, pol.ExpiryDate)
        FROM @L l
        INNER JOIN purchase.PurchaseDocumentLines pil ON pil.Id = l.InvoiceLineId
        LEFT  JOIN purchase.PurchaseDocumentLines pol ON pol.Id = pil.SourceLineId;

        IF @SupplierId IS NOT NULL AND @SupplierId <> @InvSupplier
            THROW 63000, 'The supplier must be the supplier of the purchase invoice.', 1;
        SELECT @SupplierId = @InvSupplier, @BranchId = @InvBranch, @PurchaseOrderId = NULL;
        SET @SourceText = N'Draft from invoice ' + ISNULL(@InvNo, N'#' + CAST(@PurchaseInvoiceId AS NVARCHAR(10)));
    END
    ELSE   -- Manual: "Without an order"
    BEGIN
        IF @SupplierId IS NULL THROW 63000, 'Choose the supplier: a goods receipt without an order needs one.', 1;
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsSupplier = 1 AND IsActive = 1)
            THROW 63000, 'Supplier not found, inactive, or not flagged as a supplier.', 1;
        UPDATE l
        SET SupplierId = @SupplierId, ExpectedQuantityBase = NULL, PurchaseOrderId = NULL,
            WarehouseId = COALESCE(l.WarehouseId, @WarehouseId),
            ManualUnitCostBase = COALESCE(l.ManualUnitCostBase, i.LastCost, i.AverageCost)   -- the typed cost; default the item's last cost, else its average (as Post)
        FROM @L l INNER JOIN inventory.Items i ON i.Id = l.ItemId;
        SET @PurchaseOrderId = NULL;
        SET @SourceText = N'Draft without an order (' + (SELECT PartyCode FROM masterdata.Parties WHERE Id = @SupplierId) + N')';
    END

    /* ---------- 4. Local lines (order, invoice, manual): quantity, warehouse, "Nothing more will come", caps */
    IF @SourceKind <> N'Container'
    BEGIN
        IF @WarehouseId IS NULL SELECT TOP (1) @WarehouseId = WarehouseId FROM @L WHERE WarehouseId IS NOT NULL ORDER BY LineNumber;
        IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1)
            THROW 63000, 'The warehouse the goods are received into is not found or inactive.', 1;
        -- (72) of any branch (as before), at the bottom of the tree (script 70): "Receive into" is the default of the
        --      lines, so it is held to their rule, as the default warehouse of the Excel import is.
        IF @WarehouseId IS NOT NULL AND masterdata.fn_Warehouse_IsLeaf(@WarehouseId) = 0
        BEGIN
            SET @Msg = N'The warehouse ' + (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId)
                     + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.';
            THROW 63000, @Msg, 1;
        END

        -- 0 PIECES ONLY WITH "NOTHING MORE WILL COME" on a line of an order (rules 14, 17): the usual way the rest of an
        -- order line is settled when the supplier says it will never arrive, after a partial delivery was received.
        -- The checks below still apply to such a line (an order line, a reason, an active warehouse); a line of a
        -- manual receipt or of an invoice without an order never takes 0.
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): ' +
            CASE WHEN i.IsActive = 0 THEN N'item ' + i.ItemCode + N' is inactive.'
                 WHEN l.Quantity = 0 AND l.CloseShort = 0 AND l.PoLineId IS NULL THEN N'the received quantity must be more than 0.'
                 WHEN l.Quantity = 0 AND l.CloseShort = 0
                     THEN N'the received quantity must be more than 0, or tick "Nothing more will come" to settle the rest of the order line.'
                 WHEN l.WarehouseId IS NULL THEN N'choose the warehouse the goods are received into.'
                 WHEN w.Id IS NULL OR w.IsActive = 0 THEN N'warehouse not found or inactive.'
                 -- (72) a line's warehouse is at the bottom of the tree (script 70)
                 WHEN masterdata.fn_Warehouse_IsLeaf(w.Id) = 0 THEN N'warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
                 WHEN l.PoLineId IS NULL THEN N'"Nothing more will come" applies to a line of a purchase order.'
                 ELSE N'give the reason why nothing more will come.' END
        FROM @L l
        INNER JOIN inventory.Items i          ON i.Id = l.ItemId
        LEFT  JOIN masterdata.Warehouses w    ON w.Id = l.WarehouseId
        WHERE i.IsActive = 0 OR (l.Quantity = 0 AND l.CloseShort = 0) OR l.WarehouseId IS NULL OR w.Id IS NULL OR w.IsActive = 0
           OR masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
           OR (l.CloseShort = 1 AND l.PoLineId IS NULL)
           OR (l.CloseShort = 1 AND l.VarianceReasonCode IS NULL AND l.VarianceReason IS NULL)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        -- the caps of Post (63011), so a draft never promises what cannot be posted
        SELECT TOP (1) @Msg = N'Line ' + CAST(q.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(q.Qty AS NVARCHAR(20))
                              + N' pcs received but only ' + CAST(p.MaxOutsideBase AS NVARCHAR(20))
                              + N' remain to receive on the order line outside containers.'
        FROM (SELECT PoLineId, OrderId = MIN(PurchaseOrderId), ItemId = MIN(ItemId), Qty = SUM(QuantityBase), LineNumber = MIN(LineNumber)
              FROM @L WHERE PoLineId IS NOT NULL GROUP BY PoLineId) q
        CROSS APPLY purchase.fn_PoLine_Progress(q.OrderId) p
        INNER JOIN inventory.Items i ON i.Id = q.ItemId
        WHERE p.PoLineId = q.PoLineId AND q.Qty > p.MaxOutsideBase
        ORDER BY q.LineNumber;
        IF @Msg IS NOT NULL THROW 63011, @Msg, 1;

        SELECT TOP (1) @Msg = N'Line ' + CAST(q.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(q.Qty AS NVARCHAR(20))
                              + N' pcs received but only '
                              + CAST(CASE WHEN pil.QuantityBase - pil.ReceivedQuantityBase > 0 THEN pil.QuantityBase - pil.ReceivedQuantityBase ELSE 0 END AS NVARCHAR(20))
                              + N' remain to receive on invoice ' + ISNULL(@InvNo, N'#' + CAST(@PurchaseInvoiceId AS NVARCHAR(10))) + N'.'
        FROM (SELECT InvoiceLineId, ItemId = MIN(ItemId), Qty = SUM(QuantityBase), LineNumber = MIN(LineNumber)
              FROM @L WHERE InvoiceLineId IS NOT NULL AND PoLineId IS NULL GROUP BY InvoiceLineId) q
        INNER JOIN purchase.PurchaseDocumentLines pil ON pil.Id = q.InvoiceLineId
        INNER JOIN inventory.Items i                  ON i.Id = q.ItemId
        WHERE q.Qty > pil.QuantityBase - pil.ReceivedQuantityBase
        ORDER BY q.LineNumber;
        IF @Msg IS NOT NULL THROW 63011, @Msg, 1;

        IF @BranchId IS NULL SET @BranchId = (SELECT BranchId FROM masterdata.Warehouses WHERE Id = @WarehouseId);
    END

    IF @BranchId IS NULL THROW 63000, 'Choose the branch of the goods receipt.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 63000, 'Branch not found or inactive.', 1;

    /* ---------- 5. Write */
    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            IF @SourceKind = N'Container'
            BEGIN
                -- ONE OPEN RECEIPT PER CONTAINER: the container row is locked, then the receipt is inserted only when none
                -- is open (the unique index UX_GoodsReceipts_OpenContainer would refuse a second with a raw 2601)
                DECLARE @OpenId INT, @OpenNo NVARCHAR(30);
                SELECT @CtStatus = Status FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @ContainerId;
                SELECT TOP (1) @OpenId = Id, @OpenNo = DocumentNumber
                FROM purchase.GoodsReceipts WITH (UPDLOCK, HOLDLOCK)
                WHERE ContainerId = @ContainerId AND Status < 3
                ORDER BY Status DESC, Id DESC;
                IF @OpenId IS NOT NULL
                BEGIN
                    SET @Msg = N'Container ' + @Ref + N' already has ' + ISNULL(N'goods receipt ' + @OpenNo, N'a draft goods receipt') + N'. Open it instead.';
                    THROW 63013, @Msg, 1;
                END
                IF @CtStatus NOT BETWEEN 2 AND 5
                    THROW 63010, 'Only a confirmed container that is not received yet can be received.', 1;
            END

            INSERT INTO purchase.GoodsReceipts (DocumentTypeId, DocumentDate, BranchId, WarehouseId, SupplierId, SourceKind, ContainerId,
                                                PurchaseOrderId, PurchaseInvoiceId, MovementId, IsAuto, SupplierReference, Notes, Status, CreatedBy)
            SELECT @TypeId, @DocumentDate, @BranchId, @WarehouseId, @SupplierId, @SourceKind, @ContainerId,
                   @PurchaseOrderId, @PurchaseInvoiceId, @MovementId, @IsAuto, @SupplierReference, @Notes, 1, @UserId
            WHERE @SourceKind <> N'Container'
               OR NOT EXISTS (SELECT 1 FROM purchase.GoodsReceipts x WHERE x.ContainerId = @ContainerId AND x.Status < 3);
            IF @@ROWCOUNT = 0
            BEGIN
                SET @Msg = N'Container ' + @Ref + N' already has a goods receipt. Open it instead.';
                THROW 63013, @Msg, 1;
            END
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId)
            VALUES (@Id, N'Created', LEFT(@SourceText + N' (number assigned on posting)', 500), @UserId);
            IF @SourceKind = N'Container'
                INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
                VALUES (@ContainerId, N'Event', LEFT(N'Draft goods receipt created' + ISNULL(N' when ' + @MovNo + N' was completed', N'')
                                                     + N': the goods enter the stock when it is posted.', 500), @UserId);
        END
        ELSE
        BEGIN
            UPDATE purchase.GoodsReceipts
            SET DocumentDate = @DocumentDate, BranchId = @BranchId, WarehouseId = @WarehouseId, SupplierId = @SupplierId,
                PurchaseOrderId = @PurchaseOrderId, SupplierReference = @SupplierReference, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id AND Status = 1 AND (@RowVersion IS NULL OR RowVersion = @RowVersion);
            IF @@ROWCOUNT = 0 THROW 63004, 'This goods receipt was modified by another user. Reload the page and try again.', 1;

            -- a draft has no matches; removed in case, so the lines can go
            DELETE m FROM purchase.GoodsReceiptInvoiceMatches m
            INNER JOIN purchase.GoodsReceiptLines l ON l.Id = m.GoodsReceiptLineId
            WHERE l.GoodsReceiptId = @Id;
            DELETE FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id;

            INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @L) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        -- EXPECTED = what is still to receive now, this receipt left out (its old lines are deleted above)
        IF @SourceKind = N'Order'
            UPDATE l SET ExpectedQuantityBase = p.ToReceiveBase
            FROM @L l CROSS APPLY purchase.fn_PoLine_Progress(l.PurchaseOrderId) p
            WHERE p.PoLineId = l.PoLineId;
        IF @SourceKind = N'Invoice'
            UPDATE l SET ExpectedQuantityBase = t.ToReceiveBase
            FROM @L l INNER JOIN purchase.fn_InvoiceLine_ToReceive(@PurchaseInvoiceId) t ON t.InvoiceLineId = l.InvoiceLineId;

        -- A LINE OF 0 THAT SETTLES NOTHING is refused: nothing is left to receive on its order line (or invoice line) now
        -- - everything received, settled, travelling in containers or on other draft receipts - so it would post as a no-op.
        SET @Msg = NULL;
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): nothing is left to receive on the '
                              + CASE WHEN @SourceKind = N'Invoice' THEN N'invoice line' ELSE N'order line' END
                              + N', so "Nothing more will come" has nothing to settle.'
        FROM @L l INNER JOIN inventory.Items i ON i.Id = l.ItemId
        WHERE @SourceKind <> N'Container' AND l.Quantity = 0 AND l.CloseShort = 1 AND ISNULL(l.ExpectedQuantityBase, 0) = 0
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63009, @Msg, 1;

        INSERT INTO purchase.GoodsReceiptLines (GoodsReceiptId, LineNumber, ItemId, ItemUnitId, Quantity, PackingFormula,
                                                ExpectedQuantityBase, VarianceReasonCode, VarianceReason, CloseShort, WarehouseId,
                                                SupplierId, PurchaseOrderId, PoLineId, InvoiceLineId, ContainerLineId, ExpiryDate,
                                                ManualUnitCostBase, Notes)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, l.Quantity, l.PackingFormula,
               l.ExpectedQuantityBase, l.VarianceReasonCode, l.VarianceReason, l.CloseShort, l.WarehouseId,
               l.SupplierId, l.PurchaseOrderId, l.PoLineId, l.InvoiceLineId, l.ContainerLineId, l.ExpiryDate,
               l.ManualUnitCostBase, l.Notes
        FROM @L l;

        UPDATE g
        SET TotalExpectedBase = x.Expected, TotalReceivedBase = x.Received
        FROM purchase.GoodsReceipts g
        CROSS APPLY (SELECT Expected = ISNULL(SUM(ISNULL(l.ExpectedQuantityBase, l.QuantityBase)), 0),
                            Received = ISNULL(SUM(l.QuantityBase), 0)
                     FROM purchase.GoodsReceiptLines l WHERE l.GoodsReceiptId = g.Id) x
        WHERE g.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 9. Goods receipt: why it cannot be posted */

-- Re-created (72) from the body of script 64: rows 6 and 7 also refuse a warehouse with warehouses under it - a draft
-- saved before this script. usp_GoodsReceipt_Post raises the first row (Post itself is unchanged), usp_GoodsReceipt_Get
-- shows it, so the page and the refusal say the same sentence.
CREATE OR ALTER FUNCTION purchase.fn_GoodsReceipt_PostCheck (@Id INT)
RETURNS TABLE
AS
RETURN
WITH h AS
(
    SELECT g.Id, g.Status, g.SourceKind, g.ContainerId, g.SupplierId, g.WarehouseId, g.DocumentDate,
           c.ContainerRef, CtStatus = c.Status, CtBranchId = c.BranchId
    FROM purchase.GoodsReceipts g
    LEFT JOIN logistics.Containers c ON c.Id = g.ContainerId
    WHERE g.Id = @Id
),
l AS
(
    SELECT gl.Id, gl.LineNumber, gl.ItemId, gl.QuantityBase, gl.ExpectedQuantityBase, gl.VarianceReasonCode, gl.VarianceReason,
           gl.CloseShort, gl.PoLineId, gl.PurchaseOrderId, gl.InvoiceLineId, gl.ContainerLineId,
           i.ItemCode, ItemActive = i.IsActive,
           WarehouseId = CASE WHEN h.SourceKind = N'Container' THEN h.WarehouseId ELSE COALESCE(gl.WarehouseId, h.WarehouseId) END,
           Tag = N'Line ' + CAST(gl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N')'
    FROM h
    INNER JOIN purchase.GoodsReceiptLines gl ON gl.GoodsReceiptId = h.Id
    INNER JOIN inventory.Items i             ON i.Id = gl.ItemId
)
SELECT x.Seq, x.ErrorNumber, x.Message
FROM
(
    SELECT Seq = 1, ErrorNumber = 63006, Message = CAST(N'Goods receipt not found.' AS NVARCHAR(400))
    WHERE NOT EXISTS (SELECT 1 FROM h)

    UNION ALL
    SELECT 2, 63010, N'Only a draft goods receipt can be posted.' FROM h WHERE h.Status <> 1

    UNION ALL
    SELECT 3, 63009, N'The goods receipt has no lines.' FROM h WHERE NOT EXISTS (SELECT 1 FROM l)

    UNION ALL
    SELECT 4, 63000, N'Choose the warehouse the goods are received into.'
    FROM h WHERE h.SourceKind = N'Container' AND h.WarehouseId IS NULL

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 5, ErrorNumber = 63000, Message = l.Tag + N': choose the warehouse the goods are received into.'
                   FROM l WHERE l.WarehouseId IS NULL AND l.ContainerLineId IS NULL ORDER BY l.LineNumber) a

    UNION ALL
    -- (72) + at the bottom of the tree (script 70): a draft saved before it, or a warehouse that got warehouses under it
    SELECT 6, 63000, CASE WHEN w.IsActive = 0 OR w.BranchId <> h.CtBranchId
                          THEN N'The warehouse ' + w.WarehouseCode + N' is inactive or does not belong to the branch of container ' + h.ContainerRef + N'.'
                          ELSE N'The warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.' END
    FROM h INNER JOIN masterdata.Warehouses w ON w.Id = h.WarehouseId
    WHERE h.SourceKind = N'Container' AND (w.IsActive = 0 OR w.BranchId <> h.CtBranchId OR masterdata.fn_Warehouse_IsLeaf(w.Id) = 0)

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 7, ErrorNumber = 63000,
                          Message = l.Tag + N': the warehouse ' + w.WarehouseCode
                                    + CASE WHEN w.IsActive = 0 THEN N' is inactive.'
                                           ELSE N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.' END   -- (72) script 70
                   FROM l INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
                   WHERE l.ContainerLineId IS NULL AND (w.IsActive = 0 OR masterdata.fn_Warehouse_IsLeaf(w.Id) = 0)
                   ORDER BY l.LineNumber) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 8, ErrorNumber = 63000,
                          Message = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + l.ItemCode + N' is inactive. Activate it in Item Definition before receiving it.'
                   FROM l WHERE l.ItemActive = 0 ORDER BY l.LineNumber) a

    UNION ALL
    -- one day of tolerance: the date is the reader's local date, compared with a UTC one (usp_PurchaseDocument_ValidateInput)
    SELECT 9, 63000, N'The date received cannot be in the future.'
    FROM h WHERE h.DocumentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))

    UNION ALL
    SELECT 10, 63010, N'Only a confirmed container that is not received yet can be received: ' + h.ContainerRef + N' is '
                      + CASE h.CtStatus WHEN 1 THEN N'a draft' WHEN 6 THEN N'already offloaded' WHEN 7 THEN N'closed'
                                        WHEN 8 THEN N'cancelled' ELSE N'not ready' END + N'.'
    FROM h WHERE h.SourceKind = N'Container' AND (h.CtStatus IS NULL OR h.CtStatus NOT BETWEEN 2 AND 5)

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 11, ErrorNumber = 63010,
                          Message = N'Container ' + h.ContainerRef + N' is travelling with movement ' + m.MovementNo
                                    + N'. Complete it before receiving the goods.'
                   FROM h
                   INNER JOIN logistics.MovementContainers mc ON mc.ContainerId = h.ContainerId
                   INNER JOIN logistics.Movements m           ON m.Id = mc.MovementId AND m.Status = 2
                   WHERE h.SourceKind = N'Container'
                   ORDER BY m.MovementNo) a

    UNION ALL
    -- not before the end of the container's latest completed Delivery (the rule of usp_GoodsReceipt_Save)
    SELECT 12, 63000, N'The goods cannot be received before ' + d.MovementNo + N' reached ' + d.PlaceName
                      + N' on ' + CONVERT(NVARCHAR(10), d.EndDate, 23) + N'.'
    FROM h CROSS APPLY logistics.fn_Container_LastDelivery(h.ContainerId) d
    WHERE h.SourceKind = N'Container' AND h.DocumentDate < d.EndDate

    UNION ALL
    -- the receipt mirrors the container line by line: same lines, items, order lines and loaded pieces
    SELECT 13, 63000, N'The container''s lines changed after this goods receipt was created. Delete it and receive the container again.'
    FROM h
    WHERE h.SourceKind = N'Container'
      AND (EXISTS (SELECT 1 FROM l
                   LEFT JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId AND cl.ContainerId = h.ContainerId
                   WHERE cl.Id IS NULL OR cl.ItemId <> l.ItemId OR cl.PoLineId <> ISNULL(l.PoLineId, -1)
                      OR cl.QuantityBase <> ISNULL(l.ExpectedQuantityBase, -1))
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      WHERE cl.ContainerId = h.ContainerId AND (SELECT COUNT(*) FROM l WHERE l.ContainerLineId = cl.Id) <> 1))

    UNION ALL
    -- a container's goods are received with the container's own receipt only (it updates the container and its costs)
    SELECT * FROM (SELECT TOP (1) Seq = 13, ErrorNumber = 63000,
                          Message = l.Tag + N': goods loaded in a container are received with the goods receipt of that container.'
                   FROM h INNER JOIN l ON l.ContainerLineId IS NOT NULL
                   WHERE h.SourceKind <> N'Container'
                   ORDER BY l.LineNumber) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 14, ErrorNumber = 63000,
                          Message = l.Tag + N': received ' + CAST(l.QuantityBase AS NVARCHAR(20)) + N' but only '
                                    + CAST(l.ExpectedQuantityBase AS NVARCHAR(20)) + N' were loaded.'
                   FROM l WHERE l.ContainerLineId IS NOT NULL AND l.QuantityBase > l.ExpectedQuantityBase
                   ORDER BY l.LineNumber) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 15, ErrorNumber = 63000,
                          Message = CASE WHEN l.ContainerLineId IS NOT NULL
                                         THEN l.Tag + N': choose a reason when the received quantity differs from the loaded quantity.'
                                         ELSE l.Tag + N': give the reason why nothing more will come.' END
                   FROM l
                   WHERE l.VarianceReasonCode IS NULL
                     AND ((l.ContainerLineId IS NOT NULL AND l.QuantityBase <> l.ExpectedQuantityBase)
                          OR (l.ContainerLineId IS NULL AND l.CloseShort = 1 AND NULLIF(LTRIM(RTRIM(l.VarianceReason)), N'') IS NULL))
                   ORDER BY l.LineNumber) a

    UNION ALL
    -- 0 PIECES on a local line only with "Nothing more will come" on a line of an order (usp_GoodsReceipt_Save's rule;
    -- the table only refuses a negative quantity)
    SELECT * FROM (SELECT TOP (1) Seq = 15, ErrorNumber = 63000,
                          Message = l.Tag + N': the received quantity must be more than 0.'
                   FROM l WHERE l.ContainerLineId IS NULL AND l.QuantityBase = 0 AND (l.CloseShort = 0 OR l.PoLineId IS NULL)
                   ORDER BY l.LineNumber) a

    UNION ALL
    -- a manual share of a posted charge cannot sit on a line that receives nothing (it could not enter any cost)
    SELECT * FROM (SELECT TOP (1) Seq = 16, ErrorNumber = 70013,
                          Message = N'The posted charge ' + t.ChargeName + N' has a manual share on line ' + CAST(cl.LineNumber AS NVARCHAR(10))
                                    + N' (' + i.ItemCode + N'), which receives nothing. Cancel that charge and enter it again on the received lines.'
                   FROM h
                   INNER JOIN logistics.ContainerCharges ch           ON ch.ContainerId = h.ContainerId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1
                   INNER JOIN logistics.ContainerChargeAllocations a ON a.ChargeId = ch.Id AND a.IsManual = 1 AND a.AmountBase > 0
                   INNER JOIN purchase.ChargeTypes t                  ON t.Id = ch.ChargeTypeId
                   INNER JOIN logistics.ContainerLines cl             ON cl.Id = a.ContainerLineId
                   INNER JOIN inventory.Items i                       ON i.Id = cl.ItemId
                   LEFT  JOIN l                                       ON l.ContainerLineId = cl.Id
                   WHERE h.SourceKind = N'Container' AND ISNULL(l.QuantityBase, cl.QuantityBase) = 0
                   ORDER BY cl.LineNumber) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 17, ErrorNumber = 63010,
                          Message = CASE WHEN po.Status = 3 THEN N'The purchase order ' + ISNULL(po.DocumentNumber, N'') + N' is cancelled.'
                                         ELSE N'Only an approved order can be received: the purchase order '
                                              + ISNULL(po.DocumentNumber, N'(draft)') + N' is not approved.' END
                   FROM (SELECT DISTINCT l.PurchaseOrderId FROM l WHERE l.PurchaseOrderId IS NOT NULL) x
                   INNER JOIN purchase.PurchaseDocuments po ON po.Id = x.PurchaseOrderId
                   WHERE po.Status NOT IN (2, 4)
                   ORDER BY po.Id) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 18, ErrorNumber = 63010,
                          Message = CASE WHEN d.Status = 3 THEN N'The purchase invoice ' + ISNULL(d.DocumentNumber, N'') + N' is cancelled: receive the goods from the order, or delete this goods receipt.'
                                         WHEN d.Status NOT IN (2, 4) THEN N'Post the invoice first: goods are received against a posted invoice, or from the order.'
                                         WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 THEN N'Posted before goods receipts: the stock of ' + ISNULL(d.DocumentNumber, N'') + N' entered when it was posted.'
                                         ELSE N'This invoice''s goods travel in containers: they are received with their containers.' END
                   FROM l
                   INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = l.InvoiceLineId
                   INNER JOIN purchase.PurchaseDocuments d      ON d.Id = il.DocumentId
                   WHERE d.Status NOT IN (2, 4) OR (d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1) OR il.ContainerLineId IS NOT NULL
                   ORDER BY l.LineNumber) a

    UNION ALL
    -- ORDER CAP, lines received outside containers only: their own container never counts against a container line
    SELECT * FROM (SELECT TOP (1) Seq = 19, ErrorNumber = 63011,
                          Message = N'Line ' + CAST(q.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(q.Rec AS NVARCHAR(20))
                                    + N' pcs received but only ' + CAST(p.MaxOutsideBase AS NVARCHAR(20))
                                    + N' remain to receive on the order line outside containers.'
                   FROM (SELECT l.PoLineId, l.PurchaseOrderId, Rec = SUM(l.QuantityBase), LineNumber = MIN(l.LineNumber)
                         FROM l WHERE l.PoLineId IS NOT NULL AND l.ContainerLineId IS NULL
                         GROUP BY l.PoLineId, l.PurchaseOrderId) q
                   CROSS APPLY purchase.fn_PoLine_Progress(q.PurchaseOrderId) p
                   INNER JOIN inventory.Items i ON i.Id = p.ItemId
                   WHERE p.PoLineId = q.PoLineId AND q.Rec > p.MaxOutsideBase
                   ORDER BY q.LineNumber) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 20, ErrorNumber = 63011,
                          Message = N'Line ' + CAST(q.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(q.Rec AS NVARCHAR(20))
                                    + N' pcs received but only '
                                    + CAST(CASE WHEN il.QuantityBase > il.ReceivedQuantityBase THEN il.QuantityBase - il.ReceivedQuantityBase ELSE 0 END AS NVARCHAR(20))
                                    + N' remain to receive on invoice ' + ISNULL(d.DocumentNumber, N'') + N'.'
                   FROM (SELECT l.InvoiceLineId, Rec = SUM(l.QuantityBase), LineNumber = MIN(l.LineNumber)
                         FROM l WHERE l.InvoiceLineId IS NOT NULL AND l.PoLineId IS NULL
                         GROUP BY l.InvoiceLineId) q
                   INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = q.InvoiceLineId
                   INNER JOIN purchase.PurchaseDocuments d      ON d.Id = il.DocumentId
                   INNER JOIN inventory.Items i                 ON i.Id = il.ItemId
                   WHERE q.Rec > il.QuantityBase - il.ReceivedQuantityBase
                   ORDER BY q.LineNumber) a

    UNION ALL
    -- WITHOUT AN ORDER: refused while the supplier has the item to receive on an order (or on an invoice without an order)
    SELECT * FROM (SELECT TOP (1) Seq = 21, ErrorNumber = 63011,
                          Message = s.PartyCode + N' has ' + ISNULL(po.DocumentNumber, N'an order') + N' with ' + CAST(p.OutstandingBase AS NVARCHAR(20))
                                    + N' pcs of ' + l.ItemCode + N' still to receive: receive them from the order.'
                   FROM h
                   INNER JOIN masterdata.Parties s          ON s.Id = h.SupplierId
                   INNER JOIN l                             ON l.PoLineId IS NULL AND l.InvoiceLineId IS NULL
                   INNER JOIN purchase.PurchaseDocuments po ON po.SupplierId = h.SupplierId AND po.Status IN (2, 4)
                   INNER JOIN inventory.DocumentTypes dt    ON dt.Id = po.DocumentTypeId AND dt.Code = N'PO'
                   CROSS APPLY purchase.fn_PoLine_Progress(po.Id) p
                   WHERE p.ItemId = l.ItemId AND p.OutstandingBase > 0
                   ORDER BY l.LineNumber, po.Id) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 22, ErrorNumber = 63011,
                          Message = s.PartyCode + N' has ' + ISNULL(d.DocumentNumber, N'an invoice') + N' with '
                                    + CAST(il.QuantityBase - il.ReceivedQuantityBase AS NVARCHAR(20))
                                    + N' pcs of ' + l.ItemCode + N' still to receive: receive them from the invoice.'
                   FROM h
                   INNER JOIN masterdata.Parties s              ON s.Id = h.SupplierId
                   INNER JOIN l                                 ON l.PoLineId IS NULL AND l.InvoiceLineId IS NULL
                   INNER JOIN purchase.PurchaseDocuments d      ON d.SupplierId = h.SupplierId AND d.Status IN (2, 4)
                                                               AND NOT (d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1)
                   INNER JOIN inventory.DocumentTypes dt        ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
                   INNER JOIN purchase.PurchaseDocumentLines il ON il.DocumentId = d.Id AND il.SourceLineId IS NULL AND il.ItemId = l.ItemId
                   WHERE il.QuantityBase > il.ReceivedQuantityBase
                   ORDER BY l.LineNumber, d.Id) a

    UNION ALL
    SELECT 23, 63010, N'The document type GRN is inactive: activate it in Configuration ' + NCHAR(8250) + N' Document Types.'
    WHERE NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Code = N'GRN' AND IsActive = 1)
) x;
GO

/* ================================================================== 10. Receive goods... on a container, and the Delivery hook */

-- Re-created (72) from the body of script 64: the container's warehouse becomes "Receive into" only when it is also at
-- the bottom of the tree; otherwise the draft is made without one, as for an inactive warehouse or one of another
-- branch. Nothing is refused: the completion of a Delivery never fails because of its receipts.
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_CreateForContainer
    @ContainerId  INT,
    @DocumentDate DATE         = NULL,
    @MovementId   INT          = NULL,
    @UserId       INT          = NULL,
    @Silent       BIT          = 0,
    @NewId        INT          = NULL OUTPUT,
    @SkipReason   NVARCHAR(20) = NULL OUTPUT,
    @WarehouseId  INT          = NULL,
    @Lines        purchase.tvp_GoodsReceiptLine READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @NewId = NULL;
    SET @SkipReason = NULL;

    DECLARE @Status TINYINT, @Ref NVARCHAR(30), @BranchId INT, @CtWarehouse INT, @OpenId INT, @OpenNo NVARCHAR(30),
            @OpenStatus TINYINT, @Msg NVARCHAR(400);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @Ref = ContainerRef, @BranchId = BranchId, @CtWarehouse = WarehouseId
        FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @ContainerId;
        IF @Status IS NULL THROW 63006, 'Container not found.', 1;

        SELECT TOP (1) @OpenId = Id, @OpenNo = DocumentNumber, @OpenStatus = Status
        FROM purchase.GoodsReceipts WITH (UPDLOCK, HOLDLOCK)
        WHERE ContainerId = @ContainerId AND Status < 3
        ORDER BY Status DESC, Id DESC;

        SET @SkipReason = CASE WHEN @Status = 8 THEN N'Cancelled'
                               WHEN @Status = 1 THEN N'NotConfirmed'
                               WHEN @Status IN (6, 7) OR @OpenStatus = 2 THEN N'Received'
                               WHEN @OpenStatus = 1 THEN N'HasDraft'
                               WHEN NOT EXISTS (SELECT 1 FROM logistics.ContainerLines WHERE ContainerId = @ContainerId) THEN N'NoLines' END;
        IF @SkipReason IS NOT NULL
        BEGIN
            IF @Silent = 1
            BEGIN
                COMMIT TRANSACTION;
                RETURN;
            END
            IF @OpenId IS NOT NULL
            BEGIN
                SET @Msg = N'Container ' + @Ref + N' already has ' + ISNULL(N'goods receipt ' + @OpenNo, N'a draft goods receipt') + N'. Open it instead.';
                THROW 63013, @Msg, 1;
            END
            IF @SkipReason = N'NoLines'
            BEGIN
                SET @Msg = N'Container ' + @Ref + N' has no lines to receive.';
                THROW 63009, @Msg, 1;
            END;
            THROW 63010, 'Only a confirmed container that is not received yet can be received.', 1;
        END

        -- the received pieces given by the dialog: rows of this container's lines, each once, in a unit of the item
        SELECT TOP (1) @Msg = N'Line ' + CAST(r.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN cl.Id IS NULL THEN N'it is not a line of container ' + @Ref + N'.'
                 WHEN iu.Id IS NULL THEN N'the unit does not belong to the item of the container line.'
                 WHEN r.Quantity < 0 THEN N'the received quantity cannot be negative.'
                 ELSE N'the container line is given twice.' END
        FROM @Lines r
        LEFT JOIN logistics.ContainerLines cl ON cl.Id = r.ContainerLineId AND cl.ContainerId = @ContainerId
        LEFT JOIN inventory.ItemUnits iu      ON iu.Id = r.ItemUnitId AND iu.ItemId = cl.ItemId
        WHERE cl.Id IS NULL OR iu.Id IS NULL OR r.Quantity < 0
           OR (SELECT COUNT(*) FROM @Lines d WHERE d.ContainerLineId = r.ContainerLineId) > 1
        ORDER BY r.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        DECLARE @T purchase.tvp_GoodsReceiptLine;
        INSERT INTO @T (LineNumber, ItemId, ItemUnitId, Quantity, PoLineId, ContainerLineId, ExpectedQuantityBase,
                        VarianceReasonCode, VarianceReason, CloseShort, ExpiryDate, Notes)
        SELECT ROW_NUMBER() OVER (ORDER BY cl.LineNumber), cl.ItemId, COALESCE(bu.Id, cl.ItemUnitId),
               CASE WHEN r.ContainerLineId IS NOT NULL THEN r.Quantity * iu.PackingFormula ELSE cl.QuantityBase END,
               cl.PoLineId, cl.Id, cl.QuantityBase, r.VarianceReasonCode, r.VarianceReason, 0,
               COALESCE(r.ExpiryDate, pol.ExpiryDate), r.Notes
        FROM logistics.ContainerLines cl
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
        OUTER APPLY (SELECT TOP (1) u.Id FROM inventory.ItemUnits u WHERE u.ItemId = cl.ItemId AND u.IsBaseUnit = 1 ORDER BY u.Id) bu
        LEFT  JOIN @Lines r                           ON r.ContainerLineId = cl.Id
        LEFT  JOIN inventory.ItemUnits iu             ON iu.Id = r.ItemUnitId
        WHERE cl.ContainerId = @ContainerId;

        -- AN INACTIVE ITEM: Save refuses the draft (rule 12). Silent (the Delivery hook), the container is skipped with its
        -- reason, like the other skips, so the completion goes on; otherwise Save says which line.
        IF @Silent = 1 AND EXISTS (SELECT 1 FROM @T t INNER JOIN inventory.Items i ON i.Id = t.ItemId WHERE i.IsActive = 0)
        BEGIN
            SET @SkipReason = N'InactiveItem';
            COMMIT TRANSACTION;
            RETURN;
        END

        -- "Receive into": the container's warehouse only when it can take the goods (active, of the container's branch, and
        -- (72) at the bottom of the tree, script 70); otherwise the draft is made without one, "to choose", and
        -- usp_GoodsReceipt_CreateForMovement says why
        IF @WarehouseId IS NULL
            SET @WarehouseId = (SELECT w.Id FROM masterdata.Warehouses w WHERE w.Id = @CtWarehouse AND w.IsActive = 1 AND w.BranchId = @BranchId
                                                                          AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1);
        IF @DocumentDate IS NULL
            SET @DocumentDate = COALESCE((SELECT EndDate FROM logistics.Movements WHERE Id = @MovementId), CAST(SYSUTCDATETIME() AS DATE));

        EXEC purchase.usp_GoodsReceipt_Save @SourceKind = N'Container', @ContainerId = @ContainerId, @MovementId = @MovementId,
             @DocumentDate = @DocumentDate, @BranchId = @BranchId, @WarehouseId = @WarehouseId, @Lines = @T,
             @UserId = @UserId, @NewId = @NewId OUTPUT;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 11. The drafts of a completed Delivery movement: why a warehouse is to choose */

-- Re-created (72) from the body of script 64: a draft made without a warehouse while the container has one says why
-- the container's was not taken (inactive, of another branch, or with warehouses under it). The rows keep their columns.
CREATE OR ALTER PROCEDURE purchase.usp_GoodsReceipt_CreateForMovement
    @MovementId INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;

    IF @@TRANCOUNT > 0
        THROW 63010, 'The goods receipts of a movement are created after its completion is committed, outside any transaction.', 1;

    DECLARE @Status TINYINT, @Stage NVARCHAR(10), @MovNo NVARCHAR(30), @EndDate DATE;
    SELECT @Status = m.Status, @Stage = mt.Stage, @MovNo = m.MovementNo, @EndDate = m.EndDate
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    WHERE m.Id = @MovementId;
    IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
    IF @Status <> 3 OR @Stage <> N'Delivery' THROW 70010, 'Only a completed Delivery movement creates goods receipts.', 1;

    DECLARE @Result TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ContainerId INT NOT NULL, ContainerRef NVARCHAR(30) NOT NULL,
                           GoodsReceiptId INT NULL, Created BIT NOT NULL, SkipReason NVARCHAR(20) NULL, Message NVARCHAR(400) NULL);
    DECLARE @Cid INT, @CRef NVARCHAR(30), @NewId INT, @Skip NVARCHAR(20), @Err NVARCHAR(400);

    DECLARE ctn CURSOR LOCAL FAST_FORWARD FOR
        SELECT c.Id, c.ContainerRef
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        WHERE mc.MovementId = @MovementId
        ORDER BY c.ContainerRef;
    OPEN ctn;
    FETCH NEXT FROM ctn INTO @Cid, @CRef;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @NewId = NULL, @Skip = NULL, @Err = NULL;
        BEGIN TRY
            EXEC purchase.usp_GoodsReceipt_CreateForContainer @ContainerId = @Cid, @DocumentDate = @EndDate, @MovementId = @MovementId,
                 @UserId = @UserId, @Silent = 1, @NewId = @NewId OUTPUT, @SkipReason = @Skip OUTPUT;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            SELECT @NewId = NULL, @Skip = N'Error', @Err = LEFT(ERROR_MESSAGE(), 400);
        END CATCH

        INSERT INTO @Result (ContainerId, ContainerRef, GoodsReceiptId, Created, SkipReason, Message)
        VALUES (@Cid, @CRef, COALESCE(@NewId, (SELECT r.GoodsReceiptId FROM logistics.fn_Container_ReceivedBy(@Cid) r)),
                CASE WHEN @NewId IS NOT NULL THEN 1 ELSE 0 END, @Skip, @Err);
        FETCH NEXT FROM ctn INTO @Cid, @CRef;
    END
    CLOSE ctn;
    DEALLOCATE ctn;

    SELECT r.ContainerId, r.ContainerRef, r.GoodsReceiptId, GoodsReceiptNumber = g.DocumentNumber, GoodsReceiptStatus = g.Status,
           WarehouseCode = CASE WHEN r.Created = 1 THEN w.WarehouseCode END, r.Created, r.SkipReason,
           Message = CAST(CASE
               WHEN r.Created = 1 AND w.Id IS NOT NULL THEN N'Draft goods receipt created into ' + w.WarehouseCode + N'.'
               -- (72) the container's warehouse was not taken: say why, rather than leave the reader to guess
               WHEN r.Created = 1 AND cw.Id IS NOT NULL
                   THEN N'Draft goods receipt created: choose the warehouse (' + cw.WarehouseCode + N', the container''s, '
                        + CASE WHEN cw.IsActive = 0 THEN N'is inactive'
                               WHEN cw.BranchId <> c.BranchId THEN N'is not of the container''s branch'
                               ELSE N'has warehouses under it: stock is kept only in the warehouses at the bottom of the tree' END + N').'
               WHEN r.Created = 1 THEN N'Draft goods receipt created: choose the warehouse.'
               WHEN r.SkipReason = N'Error' THEN r.Message
               WHEN r.SkipReason = N'Received' AND g.Status = 2 THEN N'Already received with goods receipt ' + g.DocumentNumber + N'.'
               WHEN r.SkipReason = N'Received' THEN N'Already offloaded.'
               WHEN r.SkipReason = N'HasDraft' THEN N'Already has a draft goods receipt.'
               WHEN r.SkipReason = N'NotConfirmed' THEN N'Not confirmed: confirm the container, then use Receive goods' + NCHAR(8230) + N' on it.'
               WHEN r.SkipReason = N'Cancelled' THEN N'The container is cancelled.'
               WHEN r.SkipReason = N'NoLines' THEN N'The container has no lines.'
               WHEN r.SkipReason = N'InactiveItem'
                   THEN N'Item ' + ISNULL(ia.ItemCode, N'?') + N' is inactive: activate it in Item Definition, then use Receive goods' + NCHAR(8230) + N' on the container.' END
               AS NVARCHAR(400))
    FROM @Result r
    LEFT JOIN purchase.GoodsReceipts g    ON g.Id = r.GoodsReceiptId
    LEFT JOIN masterdata.Warehouses w     ON w.Id = g.WarehouseId
    LEFT JOIN logistics.Containers c      ON c.Id = r.ContainerId
    LEFT JOIN masterdata.Warehouses cw    ON cw.Id = c.WarehouseId
    OUTER APPLY (SELECT TOP (1) i.ItemCode
                 FROM logistics.ContainerLines cl INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 WHERE r.SkipReason = N'InactiveItem' AND cl.ContainerId = r.ContainerId AND i.IsActive = 0
                 ORDER BY cl.LineNumber) ia
    ORDER BY r.Seq;
END
GO

/* ================================================================== 12. Movement Get: the warehouse a Delivery draft would take */

-- Re-created (72) from the body of script 65: WarehouseInBranch also needs the container's warehouse at the bottom of
-- the tree, the rule of section 10, so the Complete dialog announces what the completion will do.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT m.Id, m.DocumentTypeId, m.MovementNo, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.CountryCode AS FromCountry, fp.Kind AS FromKind,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.CountryCode AS ToCountry, tp.Kind AS ToKind,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status, m.CancelReason,
           m.CarrierPartyId, cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo, m.Reference, m.Notes,
           m.StartedAtUtc, su.FullName AS StartedByName, m.CompletedAtUtc, ku.FullName AS CompletedByName,
           m.CancelledAtUtc, xu.FullName AS CancelledByName,
           m.CreatedAtUtc, m.CreatedBy, cu.FullName AS CreatedByName, m.UpdatedAtUtc, m.UpdatedBy, uu.FullName AS UpdatedByName,
           m.RowVersion
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId
    LEFT  JOIN security.Users su ON su.Id = m.StartedBy
    LEFT  JOIN security.Users ku ON ku.Id = m.CompletedBy
    LEFT  JOIN security.Users xu ON xu.Id = m.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = m.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = m.UpdatedBy
    WHERE m.Id = @Id;

    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, c.Status AS ContainerStatus,
           c.CurrentLocation, c.TotalAllocatedBase, c.TotalOilQty,
           ItemSummary = CASE WHEN ln.ItemCount = 1 THEN ln.FirstItem WHEN ln.ItemCount > 1 THEN N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           SupplierName = ln.FirstSupplier,
           ChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id AND ch.MovementId = @Id AND ch.Status = 2),
           DraftChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id AND ch.MovementId = @Id AND ch.Status = 1),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ContainerId = c.Id AND a.MovementId = @Id),
           c.RowVersion AS ContainerRowVersion,
           -- (65) the container's open goods receipt (a draft or the posted one) and the warehouse its draft would take:
           -- the Complete dialog of a Delivery says what will be created ("draft goods receipt into LUB-WH", "warehouse to
           -- choose", "already has GRN-..."). WarehouseInBranch = the container's warehouse is active, of its branch and
           -- (72) at the bottom of the tree (script 70): the rule of usp_GoodsReceipt_CreateForContainer. AutoDraftOfThisMovement = the receipt is a draft made by
           -- this movement's completion: cancelling the movement deletes it (usp_Movement_SetStatus); the Cancel dialog
           -- names those edited since (GoodsReceiptUpdatedAtUtc / ByName, NULL when never edited).
           GoodsReceiptId = gr.GoodsReceiptId, GoodsReceiptNumber = gr.GoodsReceiptNumber, GoodsReceiptStatus = gr.GoodsReceiptStatus,
           WarehouseCode = w.WarehouseCode,
           WarehouseInBranch = CAST(CASE WHEN w.IsActive = 1 AND w.BranchId = c.BranchId AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1
                                         THEN 1 ELSE 0 END AS BIT),
           AutoDraftOfThisMovement = CAST(CASE WHEN g.Status = 1 AND g.IsAuto = 1 AND g.MovementId = @Id THEN 1 ELSE 0 END AS BIT),
           GoodsReceiptUpdatedAtUtc = g.UpdatedAtUtc, GoodsReceiptUpdatedByName = gu.FullName
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Containers c       ON c.Id = mc.ContainerId
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) gr
    LEFT  JOIN purchase.GoodsReceipts g     ON g.Id = gr.GoodsReceiptId
    LEFT  JOIN security.Users gu            ON gu.Id = g.UpdatedBy
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), FirstItem = MIN(i.ItemName), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = c.Id) ln
    WHERE mc.MovementId = @Id
    ORDER BY c.ContainerRef;

    SELECT ch.Id, ch.ContainerId, c.ContainerRef, ch.GroupId, ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description,
           pp.PartyName AS ProviderName, ch.Reference, ch.ChargeDate, cur.CurrencyCode, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.RowVersion
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    WHERE ch.MovementId = @Id
    ORDER BY ch.ChargeDate, c.ContainerRef, ch.Id;

    SELECT a.Id, a.ContainerId, c.ContainerRef, a.ChargeId, a.AttachmentTypeId, at.Category, at.SubType,
           a.FileId, f.FileName, f.ContentType, f.SizeBytes, a.Note, a.DocumentDate, a.GroupId,
           a.CreatedAtUtc, u.FullName AS CreatedByName
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Containers c        ON c.Id = a.ContainerId
    INNER JOIN logistics.Files f             ON f.Id = a.FileId
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    LEFT  JOIN security.Users u              ON u.Id = a.CreatedBy
    WHERE a.MovementId = @Id
    ORDER BY a.CreatedAtUtc DESC, c.ContainerRef;
END
GO

/* ================================================================== 13. Dashboard: what is still on order, and the goods receipt drafts */

-- Re-created (72) from the body of script 68 (Ali's dashboard, written before goods receipts): "on the way" counts
-- what the order lines still have to RECEIVE (5), and the drafts list counts the draft goods receipts (6). Every other
-- result set and column stays as it was; BIVAC Out drafts were already counted (they are stock documents).
CREATE OR ALTER PROCEDURE reporting.usp_Dashboard_Summary
    @BranchId INT  = NULL,
    @From     DATE,
    @To       DATE,
    @PrevFrom DATE,
    @PrevTo   DATE,
    @Today    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Today IS NULL SET @Today = CAST(SYSUTCDATETIME() AS DATE);

    /* 1 ---------------------------------------------------------------------------- sales */
    SELECT SalesBase           = CONVERT(DECIMAL(18,2), ISNULL(SUM(CASE WHEN d.DocumentDate BETWEEN @From AND @To THEN x.Sign * d.TotalAmountBase END), 0)),
           GrossProfitBase     = ISNULL(SUM(CASE WHEN d.DocumentDate BETWEEN @From AND @To THEN x.Sign * d.TotalGrossProfitBase END), 0),
           InvoiceCount        = ISNULL(SUM(CASE WHEN d.DocumentDate BETWEEN @From AND @To AND x.Sign = 1 THEN 1 END), 0),
           PrevSalesBase       = ISNULL(SUM(CASE WHEN d.DocumentDate BETWEEN @PrevFrom AND @PrevTo THEN x.Sign * d.TotalAmountBase END), 0),
           PrevGrossProfitBase = ISNULL(SUM(CASE WHEN d.DocumentDate BETWEEN @PrevFrom AND @PrevTo THEN x.Sign * d.TotalGrossProfitBase END), 0)
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
    CROSS APPLY (SELECT Sign = CASE t.Code WHEN N'SINV' THEN 1 WHEN N'SRET' THEN -1 ELSE 0 END) x
    WHERE d.Status = 2 AND x.Sign <> 0
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (d.DocumentDate BETWEEN @From AND @To OR d.DocumentDate BETWEEN @PrevFrom AND @PrevTo);

    /* 2 ---------------------------------------------------------------------------- receivables */
    SELECT OutstandingBase = CONVERT(DECIMAL(18,2), ISNULL(SUM(s.OutstandingAmount / NULLIF(d.ExchangeRate, 0)), 0)),
           OverdueBase     = CONVERT(DECIMAL(18,2), ISNULL(SUM(CASE WHEN d.DueDate < @Today THEN s.OutstandingAmount / NULLIF(d.ExchangeRate, 0) END), 0)),
           OpenCount       = COUNT(*),
           OverdueCount    = ISNULL(SUM(CASE WHEN d.DueDate < @Today THEN 1 END), 0)
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'SINV'
    CROSS APPLY sales.fn_InvoiceSettlement(d.Id) s
    WHERE d.Status = 2 AND s.OutstandingAmount > 0.005
      AND (@BranchId IS NULL OR d.BranchId = @BranchId);

    /* 3 ---------------------------------------------------------------------------- payables */
    SELECT InvoicesBase = (SELECT CONVERT(DECIMAL(18,2), ISNULL(SUM(s.OutstandingAmount / NULLIF(d.ExchangeRate, 0)), 0))
                           FROM purchase.PurchaseDocuments d
                           INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PINV'
                           CROSS APPLY purchase.fn_InvoiceSettlement(d.Id) s
                           WHERE d.Status = 2 AND s.OutstandingAmount > 0.005
                             AND (@BranchId IS NULL OR d.BranchId = @BranchId)),
           InvoiceCount = (SELECT COUNT(*)
                           FROM purchase.PurchaseDocuments d
                           INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PINV'
                           CROSS APPLY purchase.fn_InvoiceSettlement(d.Id) s
                           WHERE d.Status = 2 AND s.OutstandingAmount > 0.005
                             AND (@BranchId IS NULL OR d.BranchId = @BranchId)),
           ChargesBase  = (SELECT CONVERT(DECIMAL(18,2), ISNULL(SUM(s.OutstandingAmount / NULLIF(c.ExchangeRate, 0)), 0))
                           FROM logistics.ContainerCharges c
                           INNER JOIN logistics.Containers k ON k.Id = c.ContainerId
                           CROSS APPLY logistics.fn_ContainerChargeSettlement(c.Id) s
                           WHERE c.Status = 2 AND s.OutstandingAmount > 0.005
                             AND (@BranchId IS NULL OR k.BranchId = @BranchId)),
           ChargeCount  = (SELECT COUNT(*)
                           FROM logistics.ContainerCharges c
                           INNER JOIN logistics.Containers k ON k.Id = c.ContainerId
                           CROSS APPLY logistics.fn_ContainerChargeSettlement(c.Id) s
                           WHERE c.Status = 2 AND s.OutstandingAmount > 0.005
                             AND (@BranchId IS NULL OR k.BranchId = @BranchId));

    /* the stock of every item in every warehouse of the branch, used by 4 and 7 */
    DECLARE @Stock TABLE (ItemId INT NOT NULL, WarehouseId INT NOT NULL, OnHand INT NOT NULL, PRIMARY KEY (ItemId, WarehouseId));
    INSERT INTO @Stock (ItemId, WarehouseId, OnHand)
    SELECT m.ItemId, m.WarehouseId, SUM(m.QuantityBase)
    FROM inventory.StockMovements m
    INNER JOIN masterdata.Warehouses w ON w.Id = m.WarehouseId
    WHERE @BranchId IS NULL OR w.BranchId = @BranchId
    GROUP BY m.ItemId, m.WarehouseId;

    /* 4 ---------------------------------------------------------------------------- inventory */
    SELECT ValueBase    = CONVERT(DECIMAL(18,2), ISNULL(SUM(CASE WHEN s.OnHand > 0 THEN s.OnHand * ISNULL(i.AverageCost, 0) END), 0)),
           ItemsInStock = COUNT(DISTINCT CASE WHEN s.OnHand > 0 THEN s.ItemId END)
    FROM @Stock s
    INNER JOIN inventory.Items i ON i.Id = s.ItemId;

    /* 5 ---------------------------------------------------------------------------- on the way */
    -- (72) STILL TO RECEIVE, THE GOODS RECEIPTS' WAY (script 65): an order line's OutstandingBase (ordered - received -
    --      settled short; ReceivedQuantityBase is what was INVOICED, which no longer brings goods in), less the pieces of
    --      the line travelling in containers that left the supplier (In Transit, At Port, Cleared), which InTransitPieces
    --      counts - the "On order" of Shortages and of the item (rule 19), so the two figures add up without counting a
    --      piece twice.
    DECLARE @OnOrder TABLE (OrderId INT NOT NULL, Pieces INT NOT NULL);
    INSERT INTO @OnOrder (OrderId, Pieces)
    SELECT d.Id, CASE WHEN p.OutstandingBase > tr.Travelling THEN p.OutstandingBase - tr.Travelling ELSE 0 END
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PO'
    CROSS APPLY purchase.fn_PoLine_Progress(d.Id) p
    CROSS APPLY (SELECT Travelling = ISNULL((SELECT SUM(cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0))
                                             FROM logistics.ContainerLines cl
                                             INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                                             WHERE cl.PoLineId = p.PoLineId AND c.Status IN (3, 4, 5)), 0)) tr
    WHERE d.Status IN (2, 4) AND p.OutstandingBase > 0   -- a closed order still brings what was invoiced and not received
      AND (@BranchId IS NULL OR d.BranchId = @BranchId);

    SELECT OnOrderPieces = (SELECT ISNULL(SUM(o.Pieces), 0) FROM @OnOrder o),
           OpenOrders    = (SELECT COUNT(DISTINCT o.OrderId) FROM @OnOrder o),
           InTransitPieces = (SELECT ISNULL(SUM(cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0)), 0)
                            FROM logistics.ContainerLines cl
                            INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                            WHERE c.Status IN (3, 4, 5) AND cl.QuantityBase > ISNULL(cl.ReceivedQuantityBase, 0)
                              AND (@BranchId IS NULL OR c.BranchId = @BranchId)),
           ContainersInTransit = (SELECT COUNT(*) FROM logistics.Containers c
                                  WHERE c.Status IN (3, 4, 5) AND (@BranchId IS NULL OR c.BranchId = @BranchId));

    /* 6 ---------------------------------------------------------------------------- drafts */
    SELECT x.Kind, x.TypeCode, x.DraftCount
    FROM (
        SELECT Kind = N'Sales', TypeCode = t.Code, DraftCount = COUNT(*)
        FROM sales.SalesDocuments d INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
        WHERE d.Status = 1 AND (@BranchId IS NULL OR d.BranchId = @BranchId)
        GROUP BY t.Code
        UNION ALL
        SELECT N'Purchase', t.Code, COUNT(*)
        FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
        WHERE d.Status = 1 AND (@BranchId IS NULL OR d.BranchId = @BranchId)
        GROUP BY t.Code
        UNION ALL
        SELECT N'Inventory', t.Code, COUNT(*)
        FROM inventory.StockDocuments d INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId
        WHERE d.Status = 1 AND (@BranchId IS NULL OR d.BranchId = @BranchId)
        GROUP BY t.Code
        UNION ALL
        -- (72) goods receipts (script 64): a draft holds goods not in stock yet
        SELECT N'Purchase', N'GRN', COUNT(*) FROM purchase.GoodsReceipts g
        WHERE g.Status = 1 AND (@BranchId IS NULL OR g.BranchId = @BranchId)
        UNION ALL
        SELECT N'Receipt', N'RCPT', COUNT(*) FROM sales.Receipts r
        WHERE r.Status = 1 AND (@BranchId IS NULL OR r.BranchId = @BranchId)
        UNION ALL
        SELECT N'Payment', N'PAY', COUNT(*) FROM purchase.Payments p
        WHERE p.Status = 1 AND (@BranchId IS NULL OR p.BranchId = @BranchId)
    ) x
    WHERE x.DraftCount > 0;

    /* per item: the stock that counts against its minimum (the branch's, or the company's) */
    DECLARE @Item TABLE (ItemId INT PRIMARY KEY, OnHand INT NOT NULL);
    INSERT INTO @Item (ItemId, OnHand)
    SELECT i.Id, ISNULL((SELECT SUM(s.OnHand) FROM @Stock s WHERE s.ItemId = i.Id), 0)
    FROM inventory.Items i
    WHERE i.IsActive = 1 AND i.MinQuantity > 0;

    /* 7 ---------------------------------------------------------------------------- stock alerts */
    SELECT BelowMinimum      = (SELECT COUNT(*) FROM @Item x INNER JOIN inventory.Items i ON i.Id = x.ItemId WHERE x.OnHand < i.MinQuantity),
           NegativeStock     = (SELECT COUNT(*) FROM @Stock s WHERE s.OnHand < 0),
           OutOfStockSales   = (SELECT COUNT(*) FROM sales.OutOfStockSaleAudit a
                                INNER JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId
                                WHERE CAST(a.SoldAtUtc AS DATE) BETWEEN @From AND @To
                                  AND (@BranchId IS NULL OR d.BranchId = @BranchId));

    /* 8 ---------------------------------------------------------------------------- below minimum */
    SELECT TOP (5) i.Id AS ItemId, i.ItemCode, i.ItemName, x.OnHand, i.MinQuantity, Missing = i.MinQuantity - x.OnHand
    FROM @Item x INNER JOIN inventory.Items i ON i.Id = x.ItemId
    WHERE x.OnHand < i.MinQuantity
    ORDER BY i.MinQuantity - x.OnHand DESC, i.ItemCode;

    /* 9 ---------------------------------------------------------------------------- containers */
    DECLARE @Soon DATE = DATEADD(DAY, 14, @Today), @FreeDayWarning DATE = DATEADD(DAY, 7, @Today);
    SELECT ArrivingSoon    = ISNULL(SUM(CASE WHEN c.Status IN (2, 3) AND c.Eta BETWEEN @Today AND @Soon THEN 1 END), 0),
           AtPort          = ISNULL(SUM(CASE WHEN c.Status = 4 THEN 1 END), 0),
           NearLastFreeDay = ISNULL(SUM(CASE WHEN c.Status IN (4, 5) AND c.LastFreeDay IS NOT NULL AND c.LastFreeDay <= @FreeDayWarning THEN 1 END), 0)
    FROM logistics.Containers c
    WHERE @BranchId IS NULL OR c.BranchId = @BranchId;

    /* 10 --------------------------------------------------------------------------- container list */
    SELECT TOP (8) c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS StatusCode, c.Eta, c.LastFreeDay,
           Reason = CASE WHEN c.Status IN (4, 5) AND c.LastFreeDay IS NOT NULL AND c.LastFreeDay <= @FreeDayWarning
                              THEN CASE WHEN c.LastFreeDay < @Today THEN N'PastLastFreeDay' ELSE N'NearLastFreeDay' END
                         WHEN c.Status = 4 THEN N'AtPort'
                         ELSE N'ArrivingSoon' END
    FROM logistics.Containers c
    WHERE (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND ((c.Status IN (2, 3) AND c.Eta BETWEEN @Today AND @Soon)
        OR c.Status = 4
        OR (c.Status IN (4, 5) AND c.LastFreeDay IS NOT NULL AND c.LastFreeDay <= @FreeDayWarning))
    ORDER BY CASE WHEN c.LastFreeDay IS NOT NULL AND c.Status IN (4, 5) THEN c.LastFreeDay ELSE ISNULL(c.Eta, '9999-12-31') END, c.ContainerRef;

    /* 11 --------------------------------------------------------------------------- overdue */
    SELECT TOP (5) d.Id AS DocumentId, d.DocumentNumber, p.PartyName AS ClientName, d.DueDate,
           DaysOverdue = DATEDIFF(DAY, d.DueDate, @Today),
           OutstandingBase = CONVERT(DECIMAL(18,2), s.OutstandingAmount / NULLIF(d.ExchangeRate, 0))
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'SINV'
    INNER JOIN masterdata.Parties p ON p.Id = d.ClientId
    CROSS APPLY sales.fn_InvoiceSettlement(d.Id) s
    WHERE d.Status = 2 AND s.OutstandingAmount > 0.005 AND d.DueDate < @Today
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
    ORDER BY s.OutstandingAmount / NULLIF(d.ExchangeRate, 0) DESC;

    /* 12 --------------------------------------------------------------------------- cheques */
    SELECT PendingCount = COUNT(*), PendingBase = CONVERT(DECIMAL(18,2), ISNULL(SUM(l.AmountBase), 0)),
           DueCount = ISNULL(SUM(CASE WHEN l.ChequeDueDate <= @Today THEN 1 END), 0)
    FROM purchase.PaymentLines l
    INNER JOIN purchase.Payments p ON p.Id = l.PaymentId
    WHERE p.Status = 2 AND l.ClearanceStatus = 1
      AND (@BranchId IS NULL OR p.BranchId = @BranchId);

    /* 13 --------------------------------------------------------------------------- cheque list */
    SELECT TOP (5) p.Id AS PaymentId, p.PaymentNumber, pt.PartyName AS PayeeName, l.ChequeNo, l.ChequeDueDate, l.AmountBase
    FROM purchase.PaymentLines l
    INNER JOIN purchase.Payments p ON p.Id = l.PaymentId
    INNER JOIN masterdata.Parties pt ON pt.Id = p.PayeeId
    WHERE p.Status = 2 AND l.ClearanceStatus = 1
      AND (@BranchId IS NULL OR p.BranchId = @BranchId)
    ORDER BY ISNULL(l.ChequeDueDate, '9999-12-31'), p.PaymentNumber;

    /* 14 --------------------------------------------------------------------------- the base currency the money is in */
    SELECT BaseCurrencyCode = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 ORDER BY Id);
END
GO

/* ================================================================== 99. Check */

SELECT o.ObjectName, ObjectType = ISNULL(so.type_desc, N'MISSING')
FROM (VALUES (N'masterdata.fn_Warehouse_IsUsed'), (N'inventory.usp_StockDocument_ValidateInput'), (N'inventory.usp_StockDocument_Post'),
             (N'purchase.usp_PurchaseDocument_ValidateInput'), (N'purchase.usp_PurchaseDocument_Post'),
             (N'sales.usp_InvoiceImport_Validate'), (N'logistics.usp_Container_Offload'), (N'purchase.usp_GoodsReceipt_Save'),
             (N'purchase.fn_GoodsReceipt_PostCheck'), (N'purchase.usp_GoodsReceipt_CreateForContainer'),
             (N'purchase.usp_GoodsReceipt_CreateForMovement'), (N'logistics.usp_Movement_Get'),
             (N'reporting.usp_Dashboard_Summary')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(o.ObjectName)
ORDER BY ObjectType, o.ObjectName;                                    -- expected 13: 2 functions, 11 procedures, none MISSING

-- Both changes are in each merged procedure (1 = present): the BIVAC check / the goods receipts AND the leaf check.
SELECT ObjectName = o.n,
       Ours = CAST(CASE WHEN OBJECT_DEFINITION(OBJECT_ID(o.n)) LIKE N'%' + o.ours + N'%' THEN 1 ELSE 0 END AS BIT),
       Alis = CAST(CASE WHEN OBJECT_DEFINITION(OBJECT_ID(o.n)) LIKE N'%' + o.alis + N'%' THEN 1 ELSE 0 END AS BIT)
FROM (VALUES (N'inventory.usp_StockDocument_ValidateInput',   N'BivacItemsOnly',      N'fn_Warehouse_IsLeaf'),
             (N'inventory.usp_StockDocument_Post',            N'BivacItemsOnly',      N'fn_Warehouse_IsLeaf'),
             (N'purchase.usp_PurchaseDocument_ValidateInput', N'Goods Receipts',      N'fn_Warehouse_IsLeaf'),
             (N'purchase.usp_PurchaseDocument_Post',          N'usp_GoodsReceipt_',   N'fn_Warehouse_IsLeaf'),
             (N'sales.usp_InvoiceImport_Validate',            N'ErrB',                N'fn_Warehouse_IsLeaf'),
             (N'logistics.usp_Container_Offload',             N'THROW 69010',         N'THROW 69010'),
             (N'reporting.usp_Dashboard_Summary',             N'fn_PoLine_Progress',  N'DraftCount')) o (n, ours, alis)
ORDER BY o.n;                                                          -- expected 7 rows, Ours = 1 and Alis = 1 on each

-- Drafts that name a warehouse with warehouses under it (saved before script 70 or this one): each is refused at
-- posting until such a line takes a warehouse at the bottom of the tree.
SELECT x.Document, x.Id, x.Number, x.LineNumber, w.WarehouseCode
FROM (SELECT Document = N'Purchase ' + dt.Code, d.Id, Number = d.DocumentNumber, l.LineNumber, l.WarehouseId
      FROM purchase.PurchaseDocuments d
      INNER JOIN purchase.PurchaseDocumentLines l ON l.DocumentId = d.Id
      INNER JOIN inventory.DocumentTypes dt       ON dt.Id = d.DocumentTypeId
      WHERE d.Status IN (1, 5)
      UNION ALL
      SELECT N'Sales ' + dt.Code, d.Id, d.DocumentNumber, l.LineNumber, l.WarehouseId
      FROM sales.SalesDocuments d
      INNER JOIN sales.SalesDocumentLines l ON l.DocumentId = d.Id
      INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
      WHERE d.Status = 1
      UNION ALL
      SELECT N'Stock ' + dt.Code, d.Id, d.DocumentNumber, l.LineNumber, l.WarehouseId
      FROM inventory.StockDocuments d
      INNER JOIN inventory.StockDocumentLines l ON l.DocumentId = d.Id
      INNER JOIN inventory.DocumentTypes dt     ON dt.Id = d.DocumentTypeId
      WHERE d.Status = 1
      UNION ALL
      SELECT N'Goods receipt (' + g.SourceKind + N')', g.Id, g.DocumentNumber, gl.LineNumber,
             CASE WHEN g.SourceKind = N'Container' THEN g.WarehouseId ELSE COALESCE(gl.WarehouseId, g.WarehouseId) END
      FROM purchase.GoodsReceipts g
      INNER JOIN purchase.GoodsReceiptLines gl ON gl.GoodsReceiptId = g.Id
      WHERE g.Status = 1) x
INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
WHERE masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
ORDER BY x.Document, x.Id, x.LineNumber;

-- Containers not received yet whose warehouse has warehouses under it: their goods receipt is made "warehouse to
-- choose".
SELECT c.ContainerRef, c.Status, w.WarehouseCode
FROM logistics.Containers c
INNER JOIN masterdata.Warehouses w ON w.Id = c.WarehouseId
WHERE c.Status BETWEEN 1 AND 5 AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
ORDER BY c.ContainerRef;

PRINT 'Script 72 applied: the six procedures both lines of work changed hold both changes (goods receipts, BIVAC Out, '
      + 'the retired offload + any-branch leaf warehouses); goods receipts receive into warehouses at the bottom of the tree; '
      + 'the dashboard counts what is still to receive and the draft goods receipts.';
GO

SET NOEXEC OFF;
GO
