SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 65: GOODS RECEIPTS (GRN) - THE SWITCH

   From this script on, GOODS ENTER STOCK ONLY THROUGH A POSTED GOODS RECEIPT (script 64's objects). A supplier
   invoice posted from now on moves no stock and no item cost, whatever its receipt mode: it makes the amount payable
   and sets the INVOICE COST that received goods are valued at or corrected to. Documents posted before the switch keep
   their stock and their cost ("from now"). THE SWITCH IS ONE-WAY: once a goods receipt, or an invoice posted the new
   way, exists, the code before this script would receive goods twice. 64 and 65 reach main together, never 64 alone.

   Rules (spec "Goods Receipts (GRN)", sections 1 and 7; the business owner's decisions 1-8)
     - THE SWITCH, once (purchase.GoodsReceiptSwitch empty, one transaction with its marker row): every order line
       counts what was RECEIVED before goods receipts (GoodsReceivedBase: the non-reversed stock rows of old local
       invoices, the pieces of containers offloaded the old way, posted goods receipt lines) and what was SETTLED SHORT
       (GoodsShortBase: the pieces old offloads recorded short - loaded - received, always with a reason - and the
       receipt lines' settled pieces). Later starts change nothing; "99. Check" reports drift and never overwrites.
     - INVOICES: Post marks a supplier invoice UsesGoodsReceipts = 1 and moves no stock; its pieces are matched to the
       goods already received (usp_GoodsReceipt_Rematch) and their cost brought to the invoice's
       (usp_GoodsReceipt_TrueUpCost: the part in stock to the stock value, the rest to cost of sales; an exchange-rate
       difference is part of it, decision 4). "Receive the goods now" (@ReceiveNow, decision 7) receives its lines not
       in a container with a goods receipt, in a second transaction. Cancel (decision 3) is allowed when its goods were
       received: they go back to the order price. A container received with a goods receipt can still be invoiced
       (rule 19). A return takes back only what was received (rule 23), at the invoice line's current cost, from the
       warehouse the goods were received into. Purchase documents are orders, invoices and returns only (65008).
     - ORDERS close by themselves when fully invoiced AND received or settled short ("Fully invoiced and received",
       decision 2), and reopen when an invoice or goods receipt that closed them is cancelled. An order with goods
       receipts cannot be cancelled (65011), nor closed by hand while goods received on it wait for their invoice or a
       draft goods receipt waits on it (65021). What an order line committed outside containers - and so what can still
       be loaded into containers - is the larger of invoiced and received outside containers (fn_PoLine_CommittedOutside).
     - CONTAINERS: the Offload is retired (69010: "Use Receive goods..." - any confirmed container, decision 6); Cancel
       Offload only reverses an offload of the old kind (and lowers the order counters); Close needs every received
       piece invoiced (69016); a container with a goods receipt keeps its lines and branch and cannot be cancelled or
       deleted (69019); it stays "Offloaded" once received (decision 8). Cancelling a completed Delivery movement
       deletes the automatic draft receipts it created. Invoice lines a goods receipt refers to stay linked or
       unlinked (65028).
     - REPORTS: item last cost / FOB / supplier from the latest goods receipt line (or the old receipts); the stock
       statement names a receipt's supplier and source; Shortages and the item's orders use one "still to come"
       (rule 25); landed cost adjustments on an invoice that uses goods receipts adjust the received goods through the
       true-up. The order, invoice and container pages and lists show received, to receive and the goods receipts.

   Objects (each re-created with CREATE OR ALTER from its LAST definition in Schema.sql plus the change of its section)
     purchase.PurchaseDocumentLines.GoodsReceivedBase / GoodsShortBase (filled once, section 1) and the switch row
     purchase.usp_PurchaseDocument_ValidateInput (script 48), _Save / _Post / _CreateFromSource /
       _CreateFromContainers / _Get / _Search (script 63), _Cancel (script 47), _Close (script 27)
     logistics.usp_Container_InvoiceCandidates (script 27)
     logistics.usp_Movement_SetStatus (script 53), usp_Movement_Get (script 27)
     logistics.usp_Container_Offload, _CancelOffload, _Close, _Reopen, _Cancel, _Delete, _Tracking (script 27); _Save,
       _PlanFromOrder, _CreateBatch, _AvailablePoLines, _Get, _Search (script 54); logistics.fn_Container_CloseBlock (new:
       why an offloaded container cannot be closed yet - Close refuses with it, Get and Search show it)
     purchase.fn_PurchaseInvoice_ContainerState (script 63), usp_PurchaseInvoice_LinkContainers (script 51),
       usp_PurchaseInvoice_UnlinkContainer, usp_PurchaseInvoice_LinkCandidates (script 43)
     inventory.usp_Item_RebuildCosts (script 27), usp_Item_StockStatement (script 58), fn_Shortage_Live (script 62),
       usp_Item_PurchaseOrders (script 59)
     purchase.usp_LandedCostAdjustment_Save (script 27), _Post / _Cancel (script 23)
     logistics.usp_ContainerCharge_Post (script 27), usp_ContainerCharge_Cancel (script 47)

   LOCK ORDER. Every procedure here that rematches or trues up the cost of received goods - supplier invoice and return
   Post and Cancel, landed cost adjustment Post and Cancel - takes the matching lock FIRST
   (purchase.usp_GoodsReceipt_LockMatching, script 64), before any row lock or write, as goods receipt Post and Cancel
   do: taken later, two postings deadlock. The container charges read the container's status under lock, so a charge
   posted or cancelled while its container is being received waits for the receipt. Container Save, Cancel, Close and
   Reopen read the container under lock (UPDLOCK, HOLDLOCK) before their checks and write in the same transaction, as
   "Receive goods..." and goods receipt Post and Cancel hold it: the container first, then the goods receipts.

   Errors raised by the re-created objects (the goods receipt errors 63000-63013 are script 64's)
     69019 (new, 409) a container with a goods receipt: lines, branch, cancel, delete - 69010 (409) the Offload retired /
     Cancel Offload of a container received with a goods receipt - 69016 (409) Close with received pieces not invoiced -
     65011 an order with goods receipts (409) / a return above what was received (400) - 65028 (409) Link or Unlink of
     an invoice line a goods receipt refers to (Add container and Auto-plan from the invoice answer 65030 for it: rule 6
     of the invoice's containers state, from usp_PurchaseInvoice_CheckContainers) - 65021 (409) an order closed by hand
     while received goods are not invoiced or a draft goods receipt waits on it - 65008 (400) a purchase document type
     other than PO, PINV, PRET - 65019 its text names a container cancelled or offloaded before goods receipts - 67012
     (409) a landed cost adjustment on an imported invoice now also refuses a "Shipped in containers" one (receipt mode
     2), at Save and at Post - 63010 (409, script 64's) the matching lock not obtained in 60 seconds.

   Requires script 64. Idempotent, additive: re-applied at every API start-up through Schema.sql, and builds a
   brand-new empty database (it creates no table or column; the switch finds nothing to count there).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'purchase.GoodsReceiptSwitch', N'U') IS NULL
   OR COL_LENGTH(N'purchase.PurchaseDocuments', N'UsesGoodsReceipts') IS NULL
   OR COL_LENGTH(N'purchase.PurchaseDocumentLines', N'GoodsShortBase') IS NULL
   OR TYPE_ID(N'purchase.tvp_GoodsReceiptAnchor') IS NULL
   OR OBJECT_ID(N'logistics.fn_Container_ReceivedBy', N'IF') IS NULL
   OR OBJECT_ID(N'purchase.fn_PoLine_Progress', N'IF') IS NULL
   OR OBJECT_ID(N'purchase.fn_PoLine_CommittedOutside', N'IF') IS NULL
   OR OBJECT_ID(N'purchase.fn_InvoiceLine_ToReceive', N'IF') IS NULL
   OR OBJECT_ID(N'purchase.fn_GoodsReceipt_GroupLines', N'IF') IS NULL
   OR OBJECT_ID(N'purchase.usp_GoodsReceipt_LockMatching', N'P') IS NULL
   OR OBJECT_ID(N'purchase.usp_GoodsReceipt_Rematch', N'P') IS NULL
   OR OBJECT_ID(N'purchase.usp_GoodsReceipt_TrueUpCost', N'P') IS NULL
   OR OBJECT_ID(N'purchase.usp_GoodsReceipt_CreateFromInvoice', N'P') IS NULL
   OR OBJECT_ID(N'purchase.usp_GoodsReceipt_Post', N'P') IS NULL
BEGIN
    RAISERROR ('Run script 64 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. The switch: received pieces of the order lines, once */

-- THE MOMENT OF THE SWITCH (spec 7.2). From now on an order line counts what is RECEIVED (GoodsReceivedBase) next to
-- what is invoiced (ReceivedQuantityBase): every goods receipt posted or cancelled, every old invoice cancelled and
-- every old offload reversed keeps it up to date. Before that, goods entered stock in two other ways, which this batch
-- counts once, per order line:
--   (a) a local invoice posted with stock: its non-reversed PINV stock rows (the ledger, so it is right whatever the
--       invoice's flags say; a cancelled invoice has a reversal row and counts nothing - the rule of
--       usp_Item_RebuildCosts: family + type + document);
--   (b) a container offloaded the old way (fn_Container_ReceivedBy = 'Offload'): its lines' received pieces;
--   (c) a posted goods receipt line (none at the switch; counted for a database where script 64 already ran).
-- And what is SETTLED SHORT (GoodsShortBase), rule 17: an old offload received fewer pieces than were loaded only with a
-- reason (script 27), exactly as a container goods receipt settles its difference - so the pieces it recorded short
-- (loaded - received) are settled, and (c)'s receipt lines bring their SettledShortBase. Without it every old short
-- offload would count its missing pieces as still to come (Shortages, "On order", "Receive goods...") after the switch,
-- where they counted nothing before.
-- One transaction with the marker: the counters and the marker go in together or not at all, and a later start finds
-- the marker and does nothing - an administrator's data is never recomputed again (the Check section reports drift,
-- it never overwrites). Nothing else changes: no draft is flipped, no default changes, no item cost is replayed
-- (usp_Item_RebuildCosts runs on the next event of each item).
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;

    IF NOT EXISTS (SELECT 1 FROM purchase.GoodsReceiptSwitch WITH (UPDLOCK, HOLDLOCK))
    BEGIN
        DECLARE @SwitchLines INT;

        WITH inv AS
        (
            -- (a) the stock rows of local invoices posted before goods receipts, by the order line of their invoice line
            SELECT PoLineId = il.SourceLineId, Qty = SUM(m.QuantityBase)
            FROM inventory.StockMovements m
            INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = m.DocumentLineId AND il.DocumentId = m.DocumentId
            WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'PINV' AND m.IsReversal = 0
              AND il.SourceLineId IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM inventory.StockMovements r
                              WHERE r.DocumentFamily = m.DocumentFamily AND r.DocumentTypeCode = m.DocumentTypeCode
                                AND r.DocumentId = m.DocumentId AND r.IsReversal = 1)
            GROUP BY il.SourceLineId
        ),
        olo AS
        (
            -- (b) the containers offloaded the old way: received, and recorded short (loaded - received)
            SELECT cl.PoLineId, Qty = SUM(ISNULL(cl.ReceivedQuantityBase, 0)),
                   Short = SUM(CASE WHEN cl.ReceivedQuantityBase IS NOT NULL AND cl.QuantityBase > cl.ReceivedQuantityBase
                                    THEN cl.QuantityBase - cl.ReceivedQuantityBase ELSE 0 END)
            FROM logistics.ContainerLines cl
            CROSS APPLY logistics.fn_Container_ReceivedBy(cl.ContainerId) rb
            WHERE cl.PoLineId IS NOT NULL AND rb.ReceivedBy = N'Offload'
            GROUP BY cl.PoLineId
        ),
        grn AS
        (
            -- (c) posted goods receipts: received, and settled short
            SELECT gl.PoLineId, Qty = SUM(gl.QuantityBase), Short = SUM(gl.SettledShortBase)
            FROM purchase.GoodsReceiptLines gl
            INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId AND g.Status = 2
            WHERE gl.PoLineId IS NOT NULL
            GROUP BY gl.PoLineId
        )
        UPDATE pol
        SET GoodsReceivedBase = x.Qty, GoodsShortBase = x.Short
        FROM purchase.PurchaseDocumentLines pol
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = pol.DocumentId
        INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
        LEFT  JOIN inv ON inv.PoLineId = pol.Id
        LEFT  JOIN olo ON olo.PoLineId = pol.Id
        LEFT  JOIN grn ON grn.PoLineId = pol.Id
        CROSS APPLY (SELECT Qty   = ISNULL(inv.Qty, 0) + ISNULL(olo.Qty, 0) + ISNULL(grn.Qty, 0),
                            Short = ISNULL(olo.Short, 0) + ISNULL(grn.Short, 0)) x
        WHERE pol.GoodsReceivedBase <> x.Qty OR pol.GoodsShortBase <> x.Short;
        SET @SwitchLines = @@ROWCOUNT;

        INSERT INTO purchase.GoodsReceiptSwitch (Id) VALUES (1);

        PRINT 'Goods receipts switched on: received and settled pieces counted on ' + CAST(@SwitchLines AS NVARCHAR(10))
              + ' order line(s) (old local invoices, old offloads, goods receipts). From now on goods enter stock only through goods receipts.';
    END

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
SET XACT_ABORT OFF;
GO

/* ================================================================== 2. Purchase documents are orders, invoices and returns only */

-- Re-created (65) from the body of script 48: + the refusal of any other type code (65008). A goods receipt (GRN) has
-- its own tables and procedures (script 64).
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
    IF @Msg IS NOT NULL THROW 65000, @Msg, 1;
END
GO

/* ================================================================== 3. Save: goods received outside containers, returns at the invoice's cost */

-- Re-created (65) from the body of script 63:
--   - the 65026 guard (an invoice not shipped in containers cannot take pieces the containers of its order hold): what
--     is committed outside containers is MAX(invoiced outside, this invoice included; received + on draft goods receipts
--     outside) - purchase.fn_PoLine_CommittedOutside - in place of the invoiced pieces alone;
--   - a return (PRET) from an invoice that uses goods receipts, or is shipped in containers, carries the invoice line's
--     own current cost (rule 23): its landed cost, or for a container line its FOB + the container line's charges per
--     piece received; a "Shipped in containers" line that is NOT linked takes the charges of the container goods it is
--     matched to (usp_GoodsReceipt_Rematch, pass 2), weighted by the matched pieces. Returns from the other invoices
--     keep their cost as before;
--   - lines linked to containers: a container received with a goods receipt (status 6 or 7, fn_Container_ReceivedBy
--     'GRN') can be invoiced (rule 19); a cancelled one, or one offloaded before goods receipts, is still refused (65019).
-- Save never sets UsesGoodsReceipts: an invoice is marked when it is posted.
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

        -- (65) A container received with a goods receipt can still be invoiced (the goods may arrive first): only a
        --      cancelled container, or one offloaded before goods receipts, is refused.
        DECLARE @CtMsg NVARCHAR(400);
        SELECT TOP (1) @CtMsg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN cl.Id IS NULL THEN N'the container line no longer exists.'
                 WHEN c.Status = 8 OR (c.Status IN (6, 7) AND rb.ReceivedBy = N'Offload')
                      THEN N'container ' + c.ContainerRef + N' is cancelled or was offloaded before goods receipts.'
                 WHEN cl.PurchaseOrderId <> @SourceDocumentId THEN N'the container line belongs to another purchase order.'
                 WHEN cl.ItemId <> l.ItemId THEN N'the item differs from the container line.'
                 ELSE N'the order line differs from the container line.' END
        FROM @Lines l
        INNER JOIN @LineContainers x          ON x.LineNumber = l.LineNumber
        LEFT  JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
        LEFT  JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        OUTER APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
        WHERE cl.Id IS NULL OR c.Status = 8 OR (c.Status IN (6, 7) AND rb.ReceivedBy = N'Offload') OR cl.PurchaseOrderId <> @SourceDocumentId
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
        -- (65) Outside containers = MAX(invoiced outside containers, this invoice included; received outside containers +
        --      on draft goods receipts outside containers) - fn_PoLine_CommittedOutside, without this invoice. A maximum,
        --      not a sum: goods received from the order and the invoice that pays for them are the same pieces.
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
        CROSS APPLY purchase.fn_PoLine_CommittedOutside(pol.Id, @Id) co
        CROSS APPLY (SELECT Qty = CASE WHEN l.Qty + co.InvoicedOutsideBase >= co.ReceivedOutsideBase + co.InDraftReceiptsOutsideBase
                                       THEN l.Qty + co.InvoicedOutsideBase
                                       ELSE co.ReceivedOutsideBase + co.InDraftReceiptsOutsideBase END) dir
        WHERE ct.Qty > 0 AND dir.Qty + ct.Qty > pol.QuantityBase
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
               -- returns carry the LANDED cost (the container's for imports). (65) From an invoice that uses goods receipts,
               -- or is shipped in containers, the invoice line's OWN current cost: its landed cost, or for a container
               -- line its FOB + the container line's charges per piece received (the container line's FOB mixes the
               -- prices of every invoice and of the order). A line NOT linked to a container whose pieces are matched to
               -- goods received in containers (pass 2 of the matching) takes those containers' charges the same way, per
               -- matched piece; its pieces matched outside containers keep its landed cost. Worked out again when the
               -- return is posted.
               CASE WHEN @DocumentTypeCode = N'PRET' THEN
                    CASE WHEN sd.UsesGoodsReceipts = 1 OR sd.ReceiptMode = 2
                         THEN CASE WHEN scl.Id IS NOT NULL THEN src.FobCostBase + ISNULL(scl.ChargesBase / NULLIF(scl.ReceivedQuantityBase, 0), 0)
                                   WHEN mc.CtPcs > 0 THEN (mc.CtPcs * src.FobCostBase + mc.CtCharges + (mc.Pcs - mc.CtPcs) * src.UnitCostBase) / mc.Pcs
                                   ELSE src.UnitCostBase END
                         ELSE COALESCE(scl.LandedCostBase, src.UnitCostBase) END END,
               CASE WHEN @DocumentTypeCode = N'PRET' THEN
                    CASE WHEN sd.UsesGoodsReceipts = 1 OR sd.ReceiptMode = 2 THEN src.FobCostBase
                         ELSE COALESCE(scl.FobCostBase, src.FobCostBase) END END,
               l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N''), l.SourceLineId
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        LEFT  JOIN purchase.PurchaseDocumentLines src ON src.Id = l.SourceLineId
        LEFT  JOIN purchase.PurchaseDocuments sd      ON sd.Id = src.DocumentId     -- (65) the source invoice
        LEFT  JOIN logistics.ContainerLines scl       ON scl.Id = src.ContainerLineId
        -- (65) an unlinked invoice line: its matched pieces, those received in containers and their containers' charges
        OUTER APPLY (SELECT Pcs       = SUM(m.QuantityBase),
                            CtPcs     = SUM(CASE WHEN gl.ContainerLineId IS NOT NULL THEN m.QuantityBase ELSE 0 END),
                            CtCharges = SUM(CASE WHEN gl.ContainerLineId IS NOT NULL
                                                 THEN m.QuantityBase * ISNULL(mcl.ChargesBase / NULLIF(mcl.ReceivedQuantityBase, 0), 0)
                                                 ELSE 0 END)
                     FROM purchase.GoodsReceiptInvoiceMatches m
                     INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = m.GoodsReceiptLineId
                     LEFT  JOIN logistics.ContainerLines mcl  ON mcl.Id = gl.ContainerLineId
                     WHERE @DocumentTypeCode = N'PRET' AND m.InvoiceLineId = src.Id AND src.ContainerLineId IS NULL) mc;

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

/* ================================================================== 4. Post: a supplier invoice moves no stock; the cost of received goods follows it */

-- Re-created (65) from the body of script 63 (approval of 42, line warehouses of any branch of 48, one item by mode of 63):
--   - PINV, every receipt mode: no usp_Item_ApplyReceipts, no stock movements, its lines not "received" by posting. The
--     FOB, the charges and the landed cost per line are still worked out (the invoice cost). Marked UsesGoodsReceipts = 1
--     in the UPDATE that posts it; then usp_GoodsReceipt_Rematch of its groups (its order lines; supplier + item for lines
--     without an order) and usp_GoodsReceipt_TrueUpCost (cause PINV) of the posted receipt lines of those groups.
--   - 65019: a container in status 6 or 7 is refused only when it was offloaded before goods receipts; cancelled
--     containers and more than the loaded pieces are still refused.
--   - PRET from an invoice that uses goods receipts, or is shipped in containers: at most received - returned per source
--     line (65011), at the source line's current cost worked out again at posting (rule 23). Older invoices: as before.
--   - The order closes "Fully invoiced and received" when every line is invoiced and received or settled short.
--   - The audit: "...; goods are received with goods receipts", + "; cost of received goods adjusted by {amount} (stock
--     {inv}, cost of sales {cogs})" when the true-up moved something.
--   - Result (when not called by the approval): DocumentNumber + CostAdjustedBase, CostAdjustedInventoryBase,
--     CostAdjustedCogsBase, CostAdjustedLines.
--   - @ReceiveNow = 1 (decision 7, a PINV): after the commit, a goods receipt of the invoice's lines not in a container,
--     created and posted in a second transaction; @GoodsReceiptId / @GoodsReceiptNumber, or @ReceiveWarning "Invoice
--     posted; the goods receipt was not: {reason}. Use Receive goods..." (the invoice stays posted).
--   - A PINV or a PRET takes the goods receipt matching lock FIRST (usp_GoodsReceipt_LockMatching), before the header
--     lock: an invoice rematches and trues up; a return checks and raises what its invoice lines returned against what
--     they received (65011, the source lines locked), which a goods receipt posted or cancelled changes. The second
--     transaction of @ReceiveNow takes it again before it creates its receipt.
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

/* ================================================================== 5. Cancel: an invoice whose goods were received */

-- Re-created (65) from the body of script 47 (supplier payments):
--   - DECISION 3: a supplier invoice whose goods were received with goods receipts can be cancelled. It has no stock
--     effect: its lines leave the matches (usp_GoodsReceipt_Rematch of its groups, once it is cancelled) and the goods
--     received against it go back to their cost without it (usp_GoodsReceipt_TrueUpCost, cause PINVCANCEL) - the order
--     price, or another posted invoice of the same order line; goods without an order keep the cost they were received
--     at. For an invoice posted after the switch (UsesGoodsReceipts = 1) and an older "Shipped in containers" one.
--   - 69012 only for a container offloaded before goods receipts (fn_Container_ReceivedBy = 'Offload').
--   - An invoice posted with its stock before goods receipts (UsesGoodsReceipts = 0, receipt mode 1): its stock check
--     (65007) and reversal as before, and its order lines' received counter (GoodsReceivedBase) lowered by the pieces of
--     its stock rows, which the switch counted as received.
--   - A purchase order with goods receipts is refused (65011): posted ones are cancelled first, drafts deleted first.
--   - The order reopens when it was closed "Fully received" (before goods receipts) or "Fully invoiced and received".
--   - Audit: + "Cost of received goods adjusted by ..." when the true-up moved something.
--   - A PINV or a PRET takes the goods receipt matching lock FIRST (usp_GoodsReceipt_LockMatching), before the header
--     lock: an invoice rematches and trues up, a return changes what its invoice lines returned.
-- The other refusals stay: posted documents made from it (returns), posted landed cost adjustments, payments allocated.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 65000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- (65) lock order: the goods receipt matcher first, then rows, or two postings deadlock. Only a supplier invoice or
        --      a return (their type, read without a lock: it never changes).
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                   WHERE d.Id = @Id AND dt.Code IN (N'PINV', N'PRET'))
            EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @SourceId INT, @Number NVARCHAR(30), @ReceiptMode TINYINT,
                @UsesGoodsReceipts BIT, @SupplierId INT;
        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @SourceId = d.SourceDocumentId,
               @Number = d.DocumentNumber, @ReceiptMode = d.ReceiptMode, @UsesGoodsReceipts = d.UsesGoodsReceipts, @SupplierId = d.SupplierId
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status NOT IN (2, 4) THROW 65010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE SourceDocumentId = @Id AND Status IN (2, 4))
            THROW 65011, 'This document cannot be cancelled: posted documents were created from it. Cancel those first.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE SourceInvoiceId = @Id AND Status = 2)
            THROW 65011, 'This invoice cannot be cancelled: posted landed cost adjustments refer to it. Cancel those first.', 1;
        -- (47) Money paid against it would be left pointing at nothing: the payments are reversed (or de-allocated) first.
        IF EXISTS (SELECT 1 FROM purchase.PaymentAllocations a INNER JOIN purchase.Payments p ON p.Id = a.PaymentId
                   WHERE a.PurchaseDocumentId = @Id AND a.RemovedAtUtc IS NULL AND p.Status = 2)
            THROW 65011, 'This invoice cannot be cancelled: supplier payments are allocated to it. Reverse those payments (or remove the allocations) first.', 1;

        -- (65) RULE 18: goods received against an order would be left without their order. A posted receipt is
        --      cancelled first, a draft deleted first (the order's own receipts, and those of its container lines).
        IF @TypeCode = N'PO'
        BEGIN
            DECLARE @ReceiptStatus TINYINT =
                (SELECT MAX(g.Status) FROM purchase.GoodsReceipts g
                 WHERE g.Status IN (1, 2)
                   AND (g.PurchaseOrderId = @Id
                        OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = g.Id AND gl.PurchaseOrderId = @Id)));
            IF @ReceiptStatus = 2 THROW 65011, 'This purchase order has posted goods receipts. Cancel those first.', 1;
            IF @ReceiptStatus = 1 THROW 65011, 'This purchase order has draft goods receipts. Delete them first.', 1;
        END

        DECLARE @Ct NVARCHAR(400);
        IF @TypeCode = N'PO' AND EXISTS (SELECT 1 FROM logistics.ContainerLines cl INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                                         WHERE cl.PurchaseOrderId = @Id AND c.Status <> 8)
            THROW 65021, 'This purchase order is loaded into containers. Cancel those containers (or remove its lines from them) first.', 1;
        -- (65) Only a container offloaded BEFORE goods receipts received its goods with this invoice (its CNT stock rows were
        --      valued at its lines). A container received with a goods receipt keeps its goods: their cost goes back to
        --      the order price below (decision 3).
        SELECT TOP (1) @Ct = N'This invoice cannot be cancelled: container ' + c.ContainerRef + N' was already offloaded with it. Reverse the offload first.'
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
        INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
        WHERE l.DocumentId = @Id AND c.Status IN (6, 7) AND rb.ReceivedBy = N'Offload'
        ORDER BY c.ContainerRef;
        IF @Ct IS NOT NULL THROW 69012, @Ct, 1;

        -- (65) AN INVOICE POSTED WITH ITS STOCK, BEFORE GOODS RECEIPTS (UsesGoodsReceipts = 0, receipt mode 1): its stock
        --      rows are reversed below, as before. The switch counted those rows as received on the order lines
        --      (GoodsReceivedBase), so the same pieces - read from the ledger, as the switch did - leave that counter.
        DECLARE @OldStock BIT = CASE WHEN @TypeCode = N'PINV' AND @UsesGoodsReceipts = 0 AND @ReceiptMode = 1 THEN 1 ELSE 0 END;
        DECLARE @OldReceived TABLE (PoLineId INT NOT NULL PRIMARY KEY, Qty INT NOT NULL);
        IF @OldStock = 1
            INSERT INTO @OldReceived (PoLineId, Qty)
            SELECT il.SourceLineId, SUM(m.QuantityBase)
            FROM inventory.StockMovements m
            INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = m.DocumentLineId AND il.DocumentId = m.DocumentId
            WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'PINV' AND m.DocumentId = @Id AND m.IsReversal = 0
              AND il.SourceLineId IS NOT NULL
            GROUP BY il.SourceLineId;

        DECLARE @Msg NVARCHAR(400);
        -- (65) the stock check only for an invoice that brought its own stock (an invoice using goods receipts brought none)
        IF @Direction = 1 AND @ReceiptMode = 1 AND @OldStock = 1
        BEGIN
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @Id AND m.IsReversal = 0;

        IF @TypeCode = N'PINV'
            UPDATE purchase.PurchaseDocumentLines SET ReceivedQuantityBase = 0 WHERE DocumentId = @Id;

        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            -- (65) the pieces an old invoice received are no longer received (see @OldReceived)
            UPDATE s SET GoodsReceivedBase = s.GoodsReceivedBase - o.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN @OldReceived o ON o.PoLineId = s.Id;

            -- (65) closed as fully invoiced before goods receipts ("Fully received") or since ("Fully invoiced and received")
            IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 4 AND CloseReason IN (N'Fully received', N'Fully invoiced and received'))
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 2, ClosedAtUtc = NULL, ClosedBy = NULL, CloseReason = NULL WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Updated', N'Re-opened: ' + @Number + N' was cancelled', @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        UPDATE purchase.PurchaseDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        -- (65) DECISION 3: GOODS RECEIVED AGAINST THIS INVOICE GO BACK TO THEIR COST WITHOUT IT. Now that it is cancelled
        --      (its lines received nothing, above), the received pieces of its groups - each order line it invoiced, and
        --      the supplier + item of its lines without an order - are matched again without it (usp_GoodsReceipt_Rematch:
        --      to another posted invoice of the line, else unmatched) and brought to their target cost
        --      (usp_GoodsReceipt_TrueUpCost, cause PINVCANCEL): the order price, or another invoice's price; goods without
        --      an order keep the cost they were received at. The part still in stock changes the average cost, the rest
        --      goes to cost of sales. For an invoice posted after the switch (UsesGoodsReceipts = 1) and an older one
        --      "Shipped in containers" (receipt mode 2; one whose container was offloaded the old way was refused, 69012).
        DECLARE @CostAmount DECIMAL(18,2) = 0, @CostInventory DECIMAL(18,2) = 0, @CostCogs DECIMAL(18,2) = 0, @CostLines INT = 0;
        IF @TypeCode = N'PINV' AND (@UsesGoodsReceipts = 1 OR @ReceiptMode = 2)
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
                EXEC purchase.usp_GoodsReceipt_TrueUpCost @GroupLines, N'PINVCANCEL', @Id, @Number, @UserId,
                     @CostAmount OUTPUT, @CostInventory OUTPUT, @CostCogs OUTPUT, @CostLines OUTPUT;

            IF @CostLines > 0
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
                VALUES (@Id, N'Updated', LEFT(N'Cost of received goods adjusted by ' + CAST(@CostAmount AS NVARCHAR(30))
                                             + N' (stock ' + CAST(@CostInventory AS NVARCHAR(30)) + N', cost of sales '
                                             + CAST(@CostCogs AS NVARCHAR(30)) + N'): the invoice was cancelled', 500), @UserId);
        END

        -- A cancelled receipt / return changes the cost history: replay the ledger for the items concerned.
        IF @Direction <> 0
        BEGIN
            DECLARE @ItemId INT;
            DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;
            OPEN items; FETCH NEXT FROM items INTO @ItemId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC inventory.usp_Item_RebuildCosts @ItemId;
                FETCH NEXT FROM items INTO @ItemId;
            END
            CLOSE items; DEALLOCATE items;
        END

        -- containers of an import: the value basis of their charges changed
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
            VALUES (@Cid, N'Updated', LEFT(N'Purchase invoice ' + ISNULL(@Number, N'') + N' cancelled: ' + @Reason, 500), @UserId);
            FETCH NEXT FROM cts INTO @Cid;
        END
        CLOSE cts;
        DEALLOCATE cts;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 5b. Close by hand: not while received goods wait for their invoice */

-- Re-created (65) from the body of script 27: goods may now arrive before their invoice (rules 19, 20), and a closed
-- order takes no more invoices (65011) and has no Reopen - so an order closed by hand while goods received on it are
-- not invoiced would leave them at the order price for good (and a received container could never be closed, 69016).
-- Refused (65021), besides the containers not fully invoiced of script 27:
--   - a container received with a goods receipt whose received pieces are not all matched to posted invoices (the
--     test of usp_Container_Close, rule 20; the invoices may be linked to it or not - pass 2 matches by order line);
--     a container offloaded the old way, or cancelled, is not looked at, as before;
--   - an order line with more pieces received than invoiced (GoodsReceivedBase > ReceivedQuantityBase);
--   - a draft goods receipt on the order: it must be posted (or deleted) first.
-- After a close by hand, an order line expects only what was invoiced (purchase.fn_PoLine_Progress), so "Receive
-- goods..." and a draft made earlier cannot bring pieces that could never be invoiced.
-- One transaction: the matching lock first (usp_GoodsReceipt_LockMatching - the counters read here change only under
-- it, in goods receipt and invoice postings), then the order row.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Close
    @Id         INT,
    @Reason     NVARCHAR(300) = NULL,
    @RowVersion BINARY(8)     = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- lock order: the matcher first, then rows, or two postings deadlock (usp_GoodsReceipt_LockMatching)
        EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20);
        SELECT @Status = d.Status, @TypeCode = dt.Code
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;
        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PO' THROW 65010, 'Only purchase orders can be closed.', 1;
        IF @Status <> 2 THROW 65010, 'Only open (posted) purchase orders can be closed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

        DECLARE @Ct NVARCHAR(400);
        SELECT TOP (1) @Ct = CASE WHEN rb.ReceivedBy = N'GRN'
                                  THEN N'Container ' + c.ContainerRef + N' received goods of this order with goods receipt ' + rb.GoodsReceiptNumber
                                       + N' that are not invoiced yet. Post their supplier invoices (or cancel the goods receipt) before closing the order.'
                                  ELSE N'Container ' + c.ContainerRef + N' carries lines of this order that are not fully invoiced. Invoice them (or remove the lines) before closing the order.' END
        FROM logistics.ContainerLines cl
        INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
        CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
        OUTER APPLY (SELECT Q = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND pd.Status IN (2, 4)) q
        -- (65) a container received with a goods receipt: its received pieces matched to posted invoices (rule 20)
        OUTER APPLY (SELECT Received = SUM(gl.QuantityBase), Matched = SUM(mm.Qty)
                     FROM purchase.GoodsReceiptLines gl
                     INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId AND g.Status = 2
                     OUTER APPLY (SELECT Qty = SUM(m.QuantityBase) FROM purchase.GoodsReceiptInvoiceMatches m
                                  WHERE m.GoodsReceiptLineId = gl.Id) mm
                     WHERE gl.ContainerLineId = cl.Id) gx
        WHERE cl.PurchaseOrderId = @Id
          AND ((c.Status NOT IN (6, 7, 8) AND ISNULL(q.Q, 0) < cl.QuantityBase)
               OR (rb.ReceivedBy = N'GRN' AND ISNULL(gx.Matched, 0) < ISNULL(gx.Received, 0)))
        ORDER BY c.ContainerRef;
        IF @Ct IS NOT NULL THROW 65021, @Ct, 1;

        -- (65) goods received on an order line (any receipt) and not invoiced
        SELECT TOP (1) @Ct = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                             + CAST(l.GoodsReceivedBase AS NVARCHAR(20)) + N' pcs received but ' + CAST(l.ReceivedQuantityBase AS NVARCHAR(20))
                             + N' invoiced. Goods received on this order are not invoiced yet: post their supplier invoices'
                             + N' (or cancel the goods receipts) before closing it.'
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        WHERE l.DocumentId = @Id AND l.GoodsReceivedBase > l.ReceivedQuantityBase
        ORDER BY l.LineNumber;
        IF @Ct IS NOT NULL THROW 65021, @Ct, 1;

        -- (65) draft goods receipts on the order
        IF EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines gl
                   INNER JOIN purchase.GoodsReceipts g          ON g.Id = gl.GoodsReceiptId AND g.Status = 1
                   INNER JOIN purchase.PurchaseDocumentLines l  ON l.Id = gl.PoLineId
                   WHERE l.DocumentId = @Id)
            THROW 65021, 'This purchase order has draft goods receipts. Post or delete them first.', 1;

        UPDATE purchase.PurchaseDocuments
        SET Status = 4, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, CloseReason = ISNULL(NULLIF(LTRIM(RTRIM(@Reason)), N''), N'Closed manually'),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Closed', ISNULL(@Reason, N'Closed manually'), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 6. CreateFromSource: a return of what was received */

-- Re-created (65) from the body of script 63 (one invoice per item, or one): PINV -> PRET from an invoice whose goods
-- came through goods receipts (UsesGoodsReceipts = 1) or travel in containers (receipt mode 2) - rule 23:
--   - what each line can still return = received (ReceivedQuantityBase: the pieces matched to it) - returned - on draft
--     returns, as usp_PurchaseDocument_Post checks it (65011); goods received but not invoiced are not on the invoice;
--   - the line's warehouse = the warehouse of the posted goods receipt line matched to it with the most pieces (where
--     the goods are), else the invoice line's.
-- Returns from older invoices, and PO -> PINV, are unchanged. The cost of the return is set by Save and again by Post.
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

    DECLARE @SrcType NVARCHAR(20), @Status TINYINT, @BranchId INT, @WarehouseId INT, @SupplierId INT, @CurrencyId INT, @RateType TINYINT, @SupplierRef NVARCHAR(100),
            @SrcByReceipts BIT;
    SELECT @SrcType = dt.Code, @Status = d.Status, @BranchId = d.BranchId, @WarehouseId = d.WarehouseId, @SupplierId = d.SupplierId,
           @CurrencyId = d.CurrencyId, @RateType = d.RateType, @SupplierRef = d.SupplierReference,
           -- (65) rule 23: an invoice whose goods came (or come) through goods receipts - posted after the switch, or
           --      "Shipped in containers" - returns only what was RECEIVED and not returned yet
           @SrcByReceipts = CASE WHEN dt.Code = N'PINV' AND (d.UsesGoodsReceipts = 1 OR d.ReceiptMode = 2) THEN 1 ELSE 0 END
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
                                         WHEN @SrcByReceipts = 1 THEN l.ReceivedQuantityBase - l.ReturnedQuantityBase   -- (65) received, not returned
                                         ELSE l.QuantityBase - l.ReturnedQuantityBase END - ISNULL(dr.Qty, 0)) av
        WHERE l.Id IS NULL OR sel.QuantityBase <= 0 OR sel.QuantityBase > av.Available
        ORDER BY sel.SourceLineId;
        IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
    END

    -- Remaining quantity per line; when it is not a whole number of the line's unit, the new line uses the BASE unit
    -- (price converted per base unit) so nothing is over-received or over-returned.
    -- (65) A return from an invoice whose goods came through goods receipts takes them out of the warehouse they were
    --      received into: that of the posted receipt line matched to the invoice line with the most pieces (else the
    --      invoice line's).
    DECLARE @Lines purchase.tvp_PurchaseDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
    SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber), l.ItemId, c.ItemUnitId, COALESCE(rw.WarehouseId, l.WarehouseId), l.ExpiryDate,
           c.Quantity, c.UnitPrice, l.DiscountPercent, NULL, l.Notes, l.Id
    FROM purchase.PurchaseDocumentLines l
    OUTER APPLY (SELECT TOP (1) WarehouseId = COALESCE(gl.WarehouseId, g.WarehouseId)
                 FROM purchase.GoodsReceiptInvoiceMatches m
                 INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = m.GoodsReceiptLineId
                 INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId AND g.Status = 2
                 WHERE m.InvoiceLineId = l.Id AND @SrcByReceipts = 1 AND COALESCE(gl.WarehouseId, g.WarehouseId) IS NOT NULL
                 ORDER BY m.QuantityBase DESC, gl.Id) rw
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 INNER JOIN inventory.DocumentTypes xt ON xt.Id = xd.DocumentTypeId
                 WHERE x.SourceLineId = l.Id AND xd.Status = 1 AND xt.Code = @TargetTypeCode) dr
    CROSS APPLY (SELECT Available = CASE WHEN @SrcType = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                         WHEN @SrcByReceipts = 1 THEN l.ReceivedQuantityBase - l.ReturnedQuantityBase   -- (65) received, not returned
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

/* ================================================================== 7. Containers received with a goods receipt can still be invoiced */

-- Re-created (65) from the body of script 63 (one invoice per item, or one): rule 19 - the goods may arrive before their
-- invoice, so "Create Invoice from Containers..." also takes a container RECEIVED WITH A GOODS RECEIPT (Offloaded or
-- Closed, fn_Container_ReceivedBy = 'GRN'), with an empty selection too. Still refused (65019): a cancelled container
-- and one offloaded before goods receipts ("... the container is cancelled or was offloaded before goods receipts."),
-- and more than the loaded pieces not yet invoiced; a line already fully invoiced is still left out. The invoices are
-- "Shipped in containers" and linked to the container lines, as before; posting one trues up the cost of the goods
-- already received (usp_PurchaseDocument_Post).
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

    -- (65) RULE 19: the goods may arrive before the invoice. A container RECEIVED WITH A GOODS RECEIPT (Offloaded or
    --      Closed, fn_Container_ReceivedBy = 'GRN') is invoiced like one still travelling; only a cancelled container,
    --      or one offloaded before goods receipts (its goods entered stock with its invoices then), is refused - and
    --      never more than the loaded pieces.
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
        CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
        WHERE cl.PurchaseOrderId = @PurchaseOrderId AND c.Status <> 8 AND NOT (c.Status IN (6, 7) AND rb.ReceivedBy = N'Offload')
          AND cl.QuantityBase - ISNULL(q.Qty, 0) > 0;

    IF NOT EXISTS (SELECT 1 FROM @Pick) THROW 65019, 'Nothing is left to invoice on the containers of this order.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        CASE WHEN cl.Id IS NULL THEN N'A selected container line no longer exists.'
             WHEN cl.PurchaseOrderId <> @PurchaseOrderId THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' belongs to another purchase order.'
             WHEN c.Status = 8 OR (c.Status IN (6, 7) AND rb.ReceivedBy = N'Offload')
                  THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10))
                       + N': the container is cancelled or was offloaded before goods receipts.'
             WHEN p.QuantityBase <= 0 THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': the quantity must be greater than zero.'
             ELSE N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': ' + CAST(p.QuantityBase AS NVARCHAR(20))
                  + N' selected but only ' + CAST(cl.QuantityBase - ISNULL(q.Qty, 0) AS NVARCHAR(20)) + N' are loaded and not yet invoiced.' END
    FROM @Pick p
    LEFT JOIN logistics.ContainerLines cl ON cl.Id = p.ContainerLineId
    LEFT JOIN logistics.Containers c      ON c.Id = cl.ContainerId
    OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
    WHERE cl.Id IS NULL OR cl.PurchaseOrderId <> @PurchaseOrderId OR c.Status = 8 OR (c.Status IN (6, 7) AND rb.ReceivedBy = N'Offload')
       OR p.QuantityBase <= 0
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

-- Re-created (65) from the body of script 27: goods may arrive before their invoice (rule 19), so a container RECEIVED
-- WITH A GOODS RECEIPT (Offloaded or Closed, fn_Container_ReceivedBy = 'GRN') can still be invoiced. Still left out:
-- cancelled containers and containers offloaded before goods receipts (ReceivedBy = 'Offload'); a line already fully
-- invoiced unless @IncludeAll. + ReceivedBy and ReceivedBase (the pieces received on the line) at the end.
-- Container lines that can still be invoiced (containers not offloaded the old way / cancelled), by order or by container.
CREATE OR ALTER PROCEDURE logistics.usp_Container_InvoiceCandidates
    @PurchaseOrderId INT = NULL,
    @ContainerId     INT = NULL,
    @IncludeAll      BIT = 0      -- 1 = also the lines already fully invoiced
AS
BEGIN
    SET NOCOUNT ON;
    IF @PurchaseOrderId IS NULL AND @ContainerId IS NULL THROW 69000, 'Give a purchase order or a container.', 1;

    SELECT cl.Id AS ContainerLineId, cl.ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS ContainerStatus, cl.LineNumber,
           cl.PurchaseOrderId, d.DocumentNumber AS PurchaseOrderNumber, d.Status AS OrderStatus,
           d.SupplierId, sp.PartyName AS SupplierName, d.CurrencyId, cur.CurrencyCode,
           cl.PoLineId, pol.LineNumber AS PoLineNumber, cl.ItemId, i.ItemCode, i.ItemName,
           PoItemUnitId = pol.ItemUnitId, PoUnitTypeName = ut.UnitTypeName, PoPackingFormula = pol.PackingFormula,
           pol.UnitPrice, pol.DiscountPercent,
           LoadedBase         = cl.QuantityBase,
           InvoicedPostedBase = ISNULL(q.Posted, 0),
           InvoicedDraftBase  = ISNULL(q.Draft, 0),
           AvailableBase      = cl.QuantityBase - ISNULL(q.Posted, 0) - ISNULL(q.Draft, 0),
           OrderLineRemainingBase = pol.QuantityBase - pol.ReceivedQuantityBase - ISNULL(od.Draft, 0),
           rb.ReceivedBy,                                        -- (65) 'GRN' once its goods receipt is posted, else NULL
           ReceivedBase = cl.ReceivedQuantityBase                 -- (65) received by that goods receipt (NULL before)
    FROM logistics.ContainerLines cl
    INNER JOIN logistics.Containers c             ON c.Id = cl.ContainerId
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
    INNER JOIN purchase.PurchaseDocuments d       ON d.Id = cl.PurchaseOrderId
    INNER JOIN masterdata.Parties sp              ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies cur          ON cur.Id = d.CurrencyId
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
    INNER JOIN inventory.ItemUnits iu             ON iu.Id = pol.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut            ON ut.Id = iu.UnitTypeId
    INNER JOIN inventory.Items i                  ON i.Id = cl.ItemId
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN x.Status IN (2, 4) THEN pil.QuantityBase END),
                        Draft  = SUM(CASE WHEN x.Status = 1 THEN pil.QuantityBase END)
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments x ON x.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id) q
    OUTER APPLY (SELECT Draft = SUM(pil.QuantityBase)
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments x ON x.Id = pil.DocumentId
                 WHERE pil.SourceLineId = pol.Id AND x.Status = 1) od
    WHERE (c.Status NOT IN (6, 7, 8) OR rb.ReceivedBy = N'GRN')     -- (65) received with a goods receipt: still invoiceable
      AND (@PurchaseOrderId IS NULL OR cl.PurchaseOrderId = @PurchaseOrderId)
      AND (@ContainerId IS NULL OR cl.ContainerId = @ContainerId)
      AND (@IncludeAll = 1 OR cl.QuantityBase - ISNULL(q.Posted, 0) - ISNULL(q.Draft, 0) > 0)
    ORDER BY d.DocumentNumber, c.ContainerRef, cl.LineNumber;
END
GO

/* ================================================================== 8. Get: received, to receive, the goods receipts */

-- Re-created (65) from the body of script 63 (the mode of the invoice):
--   - header + UsesGoodsReceipts, CanReceive / ReceiveBlockedReason ("Receive goods...": rule 14 for an order, rule 15
--     for an invoice, with their texts; "Posted before goods receipts" also for an older "Shipped in containers" invoice
--     whose lines are all in containers offloaded the old way) and GoodsReceiptsSinceUtc (the switch, for "Posted
--     before goods receipts");
--   - order lines + the columns of purchase.fn_PoLine_Progress (received, settled short, in containers, in draft
--     receipts, to receive, the posting cap outside containers, still to come); what the line committed outside
--     containers is purchase.fn_PoLine_CommittedOutside (InvoicedDirectBase keeps its name and its place in
--     AvailableForContainerBase and holds the larger of invoiced, and received + on draft receipts; its parts at the end);
--   - invoice lines + ToReceiveBase / InDraftReceiptsBase (purchase.fn_InvoiceLine_ToReceive; 0 on a line in a
--     container); RemainingBase of an invoice whose goods come through goods receipts = received - returned (rule 23);
--   - NEW LAST result sets, so the readers of sets 1-8 keep their order: 9 the goods receipts of the document, 10 the
--     cost adjustments of received goods this invoice (or its landed cost adjustments) caused.
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
                                   THEN COALESCE(d.OneItemOnly, configuration.fn_SettingBool(N'Purchase.OneItemPerInvoice')) ELSE 0 END AS BIT),
           -- (65) goods receipts: 1 = a supplier invoice posted after the switch (its goods enter with goods receipts);
           --      CanReceive / ReceiveBlockedReason = "Receive goods..." on this order or invoice (rules 14, 15);
           --      GoodsReceiptsSinceUtc = the switch ("Posted before goods receipts ({date})")
           d.UsesGoodsReceipts,
           CanReceive = CAST(CASE WHEN rcv.Reason IS NULL THEN 1 ELSE 0 END AS BIT),
           ReceiveBlockedReason = rcv.Reason,
           GoodsReceiptsSinceUtc = (SELECT TOP (1) s.SwitchedAtUtc FROM purchase.GoodsReceiptSwitch s)
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
    -- (65) what "Receive goods..." would find: an order's lines (rule 14), an invoice's lines not in a container (rule 15)
    OUTER APPLY (SELECT ToReceive = SUM(p.ToReceiveBase), MaxOutside = SUM(p.MaxOutsideBase), InContainers = SUM(p.InContainersBase),
                        NotReceived = SUM(CASE WHEN p.OrderedBase - p.GoodsReceivedBase - p.GoodsShortBase > 0
                                               THEN p.OrderedBase - p.GoodsReceivedBase - p.GoodsShortBase ELSE 0 END),
                        InDrafts = SUM(p.InDraftReceiptsBase),
                        Room = SUM(CASE WHEN p.MaxOutsideBase > p.InDraftReceiptsBase THEN p.MaxOutsideBase - p.InDraftReceiptsBase ELSE 0 END)
                 FROM purchase.fn_PoLine_Progress(d.Id) p
                 WHERE dt.Code = N'PO') pr
    OUTER APPLY (SELECT Lines = COUNT(*), ToReceive = SUM(t.ToReceiveBase), InDrafts = SUM(t.InDraftReceiptsBase),
                        NotReceived = SUM(CASE WHEN t.InvoicedBase - t.ReceivedBase > 0 THEN t.InvoicedBase - t.ReceivedBase ELSE 0 END)
                 FROM purchase.fn_InvoiceLine_ToReceive(d.Id) t
                 WHERE dt.Code = N'PINV') ir
    -- (65) why "Receive goods..." is disabled (NULL = it is not). An order also opens it for pieces recorded short that
    --      turn up later (MaxOutsideBase: what remains outside containers, settled pieces included; the dialog proposes 0),
    --      but not for what draft goods receipts already hold (Room: MaxOutsideBase - InDraftReceiptsBase per line).
    CROSS APPLY (SELECT Reason = CAST(CASE
                     WHEN dt.Code = N'PO' THEN
                         CASE WHEN d.Status = 1 THEN N'Approve the order first: goods are received against an approved order.'
                              WHEN d.Status = 5 THEN N'This order is waiting for approval.'
                              WHEN d.Status = 3 THEN N'This order is cancelled.'
                              WHEN ISNULL(pr.ToReceive, 0) > 0 OR ISNULL(pr.Room, 0) > 0 THEN NULL
                              WHEN ISNULL(pr.InDrafts, 0) > 0
                                  THEN N'The rest of this order is on draft goods receipts: post or delete them first.'
                              WHEN ISNULL(pr.InContainers, 0) > 0 AND ISNULL(pr.NotReceived, 0) > 0
                                  THEN N'Everything still to receive travels in containers: it is received with its containers.'
                              ELSE N'Everything ordered is already received.' END
                     WHEN dt.Code = N'PINV' THEN
                         CASE WHEN d.Status = 1 THEN N'Post the invoice first: goods are received against a posted invoice, or from the order.'
                              WHEN d.Status = 3 THEN N'This invoice is cancelled.'
                              WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1
                                  THEN N'Posted before goods receipts: its stock entered when it was posted (or when its container was offloaded).'
                              -- an older "Shipped in containers" invoice whose lines are all in containers offloaded the old way
                              WHEN d.UsesGoodsReceipts = 0 AND ISNULL(ir.Lines, 0) = 0
                                   AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines x
                                                   INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
                                                   CROSS APPLY logistics.fn_Container_ReceivedBy(cl.ContainerId) rb
                                                   WHERE x.DocumentId = d.Id AND ISNULL(rb.ReceivedBy, N'') <> N'Offload')
                                  THEN N'Posted before goods receipts: its stock entered when it was posted (or when its container was offloaded).'
                              WHEN ISNULL(ir.Lines, 0) = 0 THEN N'This invoice''s goods travel in containers: they are received with their containers.'
                              WHEN ISNULL(ir.ToReceive, 0) > 0 THEN NULL
                              WHEN ISNULL(ir.InDrafts, 0) > 0 AND ISNULL(ir.NotReceived, 0) > 0
                                  THEN N'The rest of this invoice is on draft goods receipts: post or delete them first.'
                              ELSE N'Every piece of this invoice is already received.' END
                     ELSE N'A purchase return takes goods out: it is not received.' END AS NVARCHAR(400))) rcv
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
           -- (65) an invoice whose goods come through goods receipts returns what was received (rule 23), as Post checks it
           RemainingBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                WHEN dt.Code = N'PINV' AND (d.UsesGoodsReceipts = 1 OR d.ReceiptMode = 2) THEN l.ReceivedQuantityBase - l.ReturnedQuantityBase
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
           ItemLastCost = i.LastCost, ItemAverageCost = i.AverageCost, ItemFobCost = i.FobCost,
           -- (65) order lines: received, settled short, in containers / draft receipts, to receive, still to come
           --      (purchase.fn_PoLine_Progress); invoice lines: to receive with "Receive goods..." (fn_InvoiceLine_ToReceive;
           --      0 on a line in a container). InvoicedDirectBase above now holds what the order line committed outside
           --      containers (fn_PoLine_CommittedOutside: the larger of invoiced, and received + on draft receipts); its parts:
           GoodsReceivedBase   = pp.GoodsReceivedBase,
           GoodsShortBase      = pp.GoodsShortBase,
           InContainersBase    = pp.InContainersBase,
           InDraftReceiptsBase = COALESCE(pp.InDraftReceiptsBase, ip.InDraftReceiptsBase, CASE WHEN dt.Code = N'PINV' THEN 0 END),
           ToReceiveBase       = COALESCE(pp.ToReceiveBase, ip.ToReceiveBase, CASE WHEN dt.Code = N'PINV' THEN 0 END),
           MaxOutsideBase      = pp.MaxOutsideBase,
           OutstandingBase     = pp.OutstandingBase,
           InvoicedOutsideBase        = CASE WHEN dt.Code = N'PO' THEN ISNULL(dir.InvoicedOutsideBase, 0) END,
           ReceivedOutsideBase        = CASE WHEN dt.Code = N'PO' THEN ISNULL(dir.ReceivedOutsideBase, 0) END,
           InDraftReceiptsOutsideBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(dir.InDraftReceiptsOutsideBase, 0) END
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
    -- (65) committed outside containers: the larger of invoiced, and received + on draft goods receipts (was: invoiced)
    OUTER APPLY (SELECT co.Qty, co.InvoicedOutsideBase, co.ReceivedOutsideBase, co.InDraftReceiptsOutsideBase
                 FROM purchase.fn_PoLine_CommittedOutside(l.Id, NULL) co
                 WHERE dt.Code = N'PO') dir
    LEFT  JOIN purchase.fn_PoLine_Progress(@Id) pp      ON pp.PoLineId = l.Id
    LEFT  JOIN purchase.fn_InvoiceLine_ToReceive(@Id) ip ON ip.InvoiceLineId = l.Id
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

    -- 9 (65): goods receipts of the document - an order: those of its lines (from the order, its invoices, its
    --    containers); an invoice: those made from it and those whose pieces are matched to its lines. HereBase = the
    --    pieces of the receipt that concern this document (an order: on its lines; an invoice: matched to its lines,
    --    or received from it). Value = the value at receipt (fixed when posted).
    SELECT g.Id, g.DocumentNumber, g.DocumentDate, g.Status, g.SourceKind, g.IsAuto,
           g.ContainerId, ContainerRef = c.ContainerRef, g.WarehouseId, w.WarehouseCode, w.WarehouseName,
           ReceivedBase = g.TotalReceivedBase, HereBase = ISNULL(h.Pcs, 0), ValueAtReceiptBase = g.ValueAtReceiptBase,
           g.PostedAtUtc, g.CreatedAtUtc
    FROM purchase.GoodsReceipts g
    LEFT  JOIN logistics.Containers c    ON c.Id = g.ContainerId
    LEFT  JOIN masterdata.Warehouses w   ON w.Id = g.WarehouseId
    OUTER APPLY (SELECT Pcs = SUM(x.Pcs)
                 FROM (SELECT Pcs = gl.QuantityBase
                       FROM purchase.GoodsReceiptLines gl
                       WHERE gl.GoodsReceiptId = g.Id AND gl.PurchaseOrderId = @Id
                       UNION ALL
                       SELECT m.QuantityBase
                       FROM purchase.GoodsReceiptLines gl
                       INNER JOIN purchase.GoodsReceiptInvoiceMatches m ON m.GoodsReceiptLineId = gl.Id
                       INNER JOIN purchase.PurchaseDocumentLines il     ON il.Id = m.InvoiceLineId AND il.DocumentId = @Id
                       WHERE gl.GoodsReceiptId = g.Id
                       UNION ALL
                       SELECT gl.QuantityBase
                       FROM purchase.GoodsReceiptLines gl
                       INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = gl.InvoiceLineId AND il.DocumentId = @Id
                       WHERE gl.GoodsReceiptId = g.Id AND g.Status = 1) x) h
    WHERE g.PurchaseOrderId = @Id OR g.PurchaseInvoiceId = @Id
       OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = g.Id AND gl.PurchaseOrderId = @Id)
       OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines gl
                  INNER JOIN purchase.GoodsReceiptInvoiceMatches m ON m.GoodsReceiptLineId = gl.Id
                  INNER JOIN purchase.PurchaseDocumentLines il     ON il.Id = m.InvoiceLineId AND il.DocumentId = @Id
                  WHERE gl.GoodsReceiptId = g.Id)
    ORDER BY g.DocumentDate, g.Id;

    -- 10 (65): cost adjustments of received goods caused by this invoice - posted or cancelled - and by its landed
    --    cost adjustments (purchase.GoodsReceiptCostChanges; empty for an order or a return).
    SELECT cc.Id, cc.ChangedAtUtc, cc.CauseKind, cc.CauseId, cc.CauseNumber,
           cc.GoodsReceiptLineId, GoodsReceiptId = g.Id, GoodsReceiptNumber = g.DocumentNumber, gl.ItemId, i.ItemCode, i.ItemName,
           cc.ReceivedBase, cc.InStockBase, cc.FobBefore, cc.FobAfter, cc.UnitCostBefore, cc.UnitCostAfter,
           cc.AmountBase, cc.InventoryBase, cc.CogsBase
    FROM purchase.GoodsReceiptCostChanges cc
    INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = cc.GoodsReceiptLineId
    INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId
    INNER JOIN inventory.Items i             ON i.Id = gl.ItemId
    WHERE (cc.CauseKind IN (N'PINV', N'PINVCANCEL') AND cc.CauseId = @Id)
       OR (cc.CauseKind IN (N'LCA', N'LCACANCEL')
           AND cc.CauseId IN (SELECT a.Id FROM purchase.LandedCostAdjustments a WHERE a.SourceInvoiceId = @Id))
    ORDER BY cc.ChangedAtUtc, cc.Id;
END
GO

/* ================================================================== 9. Search: received and invoiced progress, "To receive" */

-- Re-created (65) from the body of script 63 (each supplier invoice's mode): ReceivedPercent of an order = pieces
-- received (GoodsReceivedBase) / ordered - it was the invoiced percent, which InvoicedPercent still gives. + the
-- invoice's UsesGoodsReceipts, and QuantityBase / ReceivedBase for the lists' "Received" progress (an order: ordered /
-- received; an invoice: invoiced / received). Two filters: @ToReceive (posted or closed orders with goods still to
-- come, the outstanding of rule 17) and @NotFullyReceived (posted or closed supplier invoices not fully received; one
-- posted with its stock before goods receipts is). Every other column, filter and sort is unchanged.
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
    @PageSize         INT          = 10,
    -- (65) goods receipts: purchase orders with goods still to come (rule 17's outstanding on a posted or closed order);
    --      supplier invoices posted or closed whose pieces are not all received (those posted with their stock before
    --      goods receipts are received)
    @ToReceive        BIT          = NULL,
    @NotFullyReceived BIT          = NULL
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
           -- (65) received = goods receipts (GoodsReceivedBase); invoiced stays below
           ReceivedPercent = CASE WHEN dt.Code = N'PO' AND ISNULL(prog.Ordered, 0) > 0 THEN CAST(100.0 * prog.GoodsReceived / prog.Ordered AS DECIMAL(5,1)) END,
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
           -- (65) the "Received" progress: pieces received of the pieces ordered (orders) or invoiced (supplier invoices; one
           --      posted with its stock before goods receipts received everything when it was posted)
           d.UsesGoodsReceipts,
           QuantityBase = CASE WHEN dt.Code IN (N'PO', N'PINV') THEN ISNULL(prog.Ordered, 0) END,
           ReceivedBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(prog.GoodsReceived, 0)
                               WHEN dt.Code = N'PINV' AND d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 AND d.Status IN (2, 4) THEN ISNULL(prog.Ordered, 0)
                               WHEN dt.Code = N'PINV' THEN ISNULL(prog.Invoiced, 0) END,
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
    -- Invoiced = ReceivedQuantityBase: invoiced on an order line, received (matched) on an invoice line
    OUTER APPLY (SELECT Ordered = SUM(QuantityBase), Invoiced = SUM(ReceivedQuantityBase), GoodsReceived = SUM(GoodsReceivedBase)
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
      AND (ISNULL(@ToReceive, 0) = 0 OR (dt.Code = N'PO' AND d.Status IN (2, 4)
           AND EXISTS (SELECT 1 FROM purchase.fn_PoLine_Progress(d.Id) p WHERE p.OutstandingBase > 0)))
      AND (ISNULL(@NotFullyReceived, 0) = 0 OR (dt.Code = N'PINV' AND d.Status IN (2, 4)
           AND NOT (d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1)
           AND ISNULL(prog.Invoiced, 0) < ISNULL(prog.Ordered, 0)))
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

/* ================================================================== 10. Movements: cancelling a completed Delivery */

-- Re-created (65) from the body of script 53: Cancel of a completed movement deletes the automatic draft goods receipts
-- its completion created (rule 22). Complete is unchanged: the API creates the drafts after the commit.
-- Status changes of a movement. @Action: Start | Complete | Cancel. The containers' status and dates follow.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_SetStatus
    @Id         INT,
    @Action     NVARCHAR(10),
    @Date       DATE          = NULL,    -- Start: start date; Complete: end date (default today)
    @Reason     NVARCHAR(300) = NULL,    -- Cancel
    @RowVersion BINARY(8)     = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Action = NULLIF(LTRIM(RTRIM(@Action)), N'');
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Date IS NULL SET @Date = CAST(SYSUTCDATETIME() AS DATE);
    IF @Action IS NULL OR @Action NOT IN (N'Start', N'Complete', N'Cancel') THROW 70000, 'Action must be Start, Complete or Cancel.', 1;

    DECLARE @Status TINYINT, @StartDate DATE, @Label NVARCHAR(300), @FromPlaceId INT, @ToPlaceId INT, @MovementTypeId INT,
            @MovementNo NVARCHAR(30);
    SELECT @Status = m.Status, @StartDate = m.StartDate, @MovementNo = m.MovementNo,
           @FromPlaceId = m.FromPlaceId, @ToPlaceId = m.ToPlaceId, @MovementTypeId = m.MovementTypeId,
           @Label = m.MovementNo + N' ' + mt.TypeName + N': ' + fp.PortName + N' ' + NCHAR(8594) + N' ' + tp.PortName
    FROM logistics.Movements m WITH (UPDLOCK, HOLDLOCK)
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp ON tp.Id = m.ToPlaceId
    WHERE m.Id = @Id;

    IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 70004, 'This movement was modified by another user. Reload the page and try again.', 1;
    IF @Action = N'Start' AND @Status <> 1 THROW 70010, 'Only a planned movement can be started.', 1;
    IF @Action = N'Complete' AND @Status <> 2 THROW 70010, 'Only a movement in progress can be completed.', 1;
    IF @Action = N'Complete' AND @Date < @StartDate THROW 70000, 'The end date cannot be earlier than the start date.', 1;
    IF @Action = N'Cancel' AND @Status = 4 THROW 70010, 'The movement is already cancelled.', 1;
    IF @Action = N'Cancel' AND @Reason IS NULL THROW 70000, 'A cancellation reason is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.MovementContainers WHERE MovementId = @Id) AND @Action = N'Start'
        THROW 70000, 'Tick at least one container before starting.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.MovementContainers WHERE MovementId = @Id) AND @Action = N'Complete'
        THROW 70000, 'The movement has no containers.', 1;

    DECLARE @Msg NVARCHAR(400);
    IF @Action = N'Start'
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + CASE WHEN c.Status = 1 THEN N' is not confirmed yet.'
                                                                    ELSE N' is already offloaded, closed or cancelled.' END
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        WHERE mc.MovementId = @Id AND (c.Status = 1 OR c.Status >= 6)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is already travelling with movement ' + m.MovementNo + N'. Complete it first.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c         ON c.Id = mc.ContainerId
        INNER JOIN logistics.MovementContainers o ON o.ContainerId = mc.ContainerId AND o.MovementId <> @Id
        INNER JOIN logistics.Movements m          ON m.Id = o.MovementId AND m.Status = 2
        WHERE mc.MovementId = @Id
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70012, @Msg, 1;

        -- the place rules (script 53): the previous movement of every container is completed (70016), then every
        -- container fits the movement's From, To and stage (70015) - the rules of Save, fn_ContainerFitForMovement
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N': the previous movement ' + p.PreviousMovementNo + N' (' + pf.PortName
                              + N' ' + NCHAR(8594) + N' ' + p.PlaceName + N') is not completed yet.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        INNER JOIN logistics.fn_ContainerPlaceForMovement(@Id) p ON p.ContainerId = mc.ContainerId
        INNER JOIN logistics.Movements pm ON pm.Id = p.PreviousMovementId
        INNER JOIN masterdata.Ports pf    ON pf.Id = pm.FromPlaceId
        WHERE mc.MovementId = @Id AND p.PreviousStatus <> 3
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70016, @Msg, 1;

        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' cannot leave from ' + f.PortName + N'. ' + p.Reason
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        INNER JOIN logistics.fn_ContainerFitForMovement(@Id, @FromPlaceId, @ToPlaceId, @MovementTypeId) p ON p.ContainerId = mc.ContainerId
        INNER JOIN masterdata.Ports f     ON f.Id = @FromPlaceId
        WHERE mc.MovementId = @Id AND p.Fits = 0
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70015, @Msg, 1;
    END
    IF @Action = N'Cancel'
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is already offloaded: its route can no longer change.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        WHERE mc.MovementId = @Id AND c.Status IN (6, 7) AND @Status IN (2, 3)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70010, @Msg, 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE logistics.Movements
        SET Status = CASE @Action WHEN N'Start' THEN 2 WHEN N'Complete' THEN 3 ELSE 4 END,
            StartDate = CASE WHEN @Action = N'Start' THEN @Date ELSE StartDate END,
            EndDate = CASE WHEN @Action = N'Complete' THEN @Date ELSE EndDate END,
            StartedAtUtc = CASE WHEN @Action = N'Start' THEN SYSUTCDATETIME() ELSE StartedAtUtc END,
            StartedBy = CASE WHEN @Action = N'Start' THEN @UserId ELSE StartedBy END,
            CompletedAtUtc = CASE WHEN @Action = N'Complete' THEN SYSUTCDATETIME() ELSE CompletedAtUtc END,
            CompletedBy = CASE WHEN @Action = N'Complete' THEN @UserId ELSE CompletedBy END,
            CancelledAtUtc = CASE WHEN @Action = N'Cancel' THEN SYSUTCDATETIME() ELSE CancelledAtUtc END,
            CancelledBy = CASE WHEN @Action = N'Cancel' THEN @UserId ELSE CancelledBy END,
            CancelReason = CASE WHEN @Action = N'Cancel' THEN @Reason ELSE CancelReason END,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT mc.ContainerId, N'Event',
               LEFT(CASE @Action WHEN N'Start' THEN N'Started ' WHEN N'Complete' THEN N'Arrived / completed ' ELSE N'Cancelled ' END
                    + @Label + N' on ' + CONVERT(NVARCHAR(10), @Date, 23) + ISNULL(N' - ' + @Reason, N''), 500),
               @UserId
        FROM logistics.MovementContainers mc WHERE mc.MovementId = @Id;

        -- (65) RULE 22: CANCELLING A COMPLETED DELIVERY TAKES BACK THE DRAFT GOODS RECEIPTS ITS COMPLETION CREATED (IsAuto,
        -- MovementId = this movement), edited or not - the cancel dialog names the edited ones first (usp_Movement_Get).
        -- A draft made by hand is kept. A posted receipt made its container Offloaded, so the check above refused the
        -- cancel. The same plain deletes as usp_GoodsReceipt_Delete: a draft has no stock, number or cost to undo.
        IF @Action = N'Cancel' AND @Status = 3
        BEGIN
            DECLARE @AutoDrafts TABLE (Id INT NOT NULL PRIMARY KEY, ContainerId INT NOT NULL);
            INSERT INTO @AutoDrafts (Id, ContainerId)
            SELECT g.Id, g.ContainerId
            FROM purchase.GoodsReceipts g WITH (UPDLOCK, HOLDLOCK)
            WHERE g.MovementId = @Id AND g.IsAuto = 1 AND g.Status = 1;

            IF EXISTS (SELECT 1 FROM @AutoDrafts)
            BEGIN
                DELETE m FROM purchase.GoodsReceiptInvoiceMatches m
                INNER JOIN purchase.GoodsReceiptLines l ON l.Id = m.GoodsReceiptLineId
                INNER JOIN @AutoDrafts d                ON d.Id = l.GoodsReceiptId;
                DELETE f FROM purchase.GoodsReceiptFiles f INNER JOIN @AutoDrafts d ON d.Id = f.GoodsReceiptId;
                DELETE l FROM purchase.GoodsReceiptLines l INNER JOIN @AutoDrafts d ON d.Id = l.GoodsReceiptId;
                DELETE a FROM purchase.GoodsReceiptAudit a INNER JOIN @AutoDrafts d ON d.Id = a.GoodsReceiptId;
                DELETE g FROM purchase.GoodsReceipts g INNER JOIN @AutoDrafts d ON d.Id = g.Id;

                INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
                SELECT d.ContainerId, N'Event', LEFT(N'Draft goods receipt removed: movement ' + @MovementNo + N' cancelled', 500), @UserId
                FROM @AutoDrafts d;
            END
        END

        DECLARE @Cid INT;
        DECLARE ctn CURSOR LOCAL FAST_FORWARD FOR SELECT ContainerId FROM logistics.MovementContainers WHERE MovementId = @Id;
        OPEN ctn;
        FETCH NEXT FROM ctn INTO @Cid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_RefreshStatus @Cid;
            FETCH NEXT FROM ctn INTO @Cid;
        END
        CLOSE ctn;
        DEALLOCATE ctn;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 11. The container Offload is retired */

-- Re-created (65) from the body of script 27 as a refusal (rule 26): containers are received with a goods receipt
-- (purchase.usp_GoodsReceipt_CreateForContainer, then _Post), which does what the offload did. The parameters stay,
-- so an old caller gets the reason rather than an error about the call.
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

/* ================================================================== 12. Cancel Offload: offloads of the old kind only */

-- Re-created (65) from the body of script 27: refused (69010) for a container received with a goods receipt; the order
-- lines' received and settled-short counters (GoodsReceivedBase, GoodsShortBase) follow the reversal, and an order
-- closed as fully invoiced and received opens again.
-- Reverses an offload: movements reversed, invoice lines released, charges spread again (not frozen), costs replayed.
-- Refused once a charge changed the item costs after the offload (69018).
CREATE OR ALTER PROCEDURE logistics.usp_Container_CancelOffload
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 69000, 'A reason is required.', 1;

    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @Id);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;

    -- (65) RULE 26: ONLY AN OFFLOAD OF THE OLD KIND (script 27, fn_Container_ReceivedBy = 'Offload') IS REVERSED HERE. A
    -- container received with a goods receipt is un-received by cancelling that receipt (usp_GoodsReceipt_Cancel), which
    -- also re-matches its invoices and trues up the costs; the status check below refuses the rest (2-5, 7, 8).
    DECLARE @Msg NVARCHAR(400);
    SELECT @Msg = N'This container was received with goods receipt ' + r.GoodsReceiptNumber + N': cancel that goods receipt instead.'
    FROM logistics.fn_Container_ReceivedBy(@Id) r
    WHERE r.ReceivedBy = N'GRN';
    IF @Msg IS NOT NULL THROW 69010, @Msg, 1;

    IF @Status <> 6 THROW 69010, 'Only an offloaded container that is not closed can be reversed.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
    IF EXISTS (SELECT 1 FROM inventory.CostAdjustments ca
               INNER JOIN logistics.ContainerCharges ch ON ch.Id = ca.SourceId
               WHERE ca.SourceKind = N'CNTCHARGE' AND ch.ContainerId = @Id)
        THROW 69018, 'Charges were posted or cancelled after the offload and the item costs were adjusted. The offload can no longer be reversed.', 1;

    -- the offload to reverse = the latest one of this container that is not reversed yet
    DECLARE @Tag NVARCHAR(30) =
        (SELECT TOP (1) m.DocumentNumber FROM inventory.StockMovements m
         WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0
           AND NOT EXISTS (SELECT 1 FROM inventory.StockMovements r
                           WHERE r.DocumentFamily = m.DocumentFamily AND r.DocumentTypeCode = m.DocumentTypeCode
                             AND r.DocumentId = m.DocumentId AND r.DocumentNumber = m.DocumentNumber AND r.IsReversal = 1)
         ORDER BY m.Id DESC);

    SELECT TOP (1) @Msg = N'Cannot reverse: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                         + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20))
                         + N' left, but this container brought ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
    FROM (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
          FROM inventory.StockMovements m
          WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0
            AND m.DocumentNumber = @Tag
          GROUP BY m.ItemId, m.WarehouseId) x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
    WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
    ORDER BY i.ItemCode;
    IF @Msg IS NOT NULL THROW 69015, @Msg, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0
          AND m.DocumentNumber = @Tag;

        -- the invoice lines of the container were received only by this offload
        UPDATE pl SET ReceivedQuantityBase = 0
        FROM purchase.PurchaseDocumentLines pl
        INNER JOIN logistics.ContainerLines cl ON cl.Id = pl.ContainerLineId
        WHERE cl.ContainerId = @Id;

        DECLARE @Items TABLE (ItemId INT PRIMARY KEY);
        INSERT INTO @Items (ItemId) SELECT DISTINCT ItemId FROM logistics.ContainerLines WHERE ContainerId = @Id;

        -- (65) THE ORDER LINES NO LONGER COUNT THESE PIECES AS RECEIVED, NOR THE MISSING ONES AS SETTLED: script 65
        -- filled GoodsReceivedBase from the offloads of the old kind (the received pieces of their container lines) and
        -- GoodsShortBase from what they recorded short (loaded - received), before they are cleared below. An order that
        -- closed as fully invoiced and received opens again; one closed "Fully received" (the old wording of fully
        -- invoiced) stays closed - the reversal changes nothing invoiced.
        UPDATE pol
        SET GoodsReceivedBase = pol.GoodsReceivedBase - x.Rec, GoodsShortBase = pol.GoodsShortBase - x.Short
        FROM purchase.PurchaseDocumentLines pol
        INNER JOIN (SELECT PoLineId, Rec = SUM(ReceivedQuantityBase),
                           Short = SUM(CASE WHEN QuantityBase > ReceivedQuantityBase THEN QuantityBase - ReceivedQuantityBase ELSE 0 END)
                    FROM logistics.ContainerLines
                    WHERE ContainerId = @Id AND PoLineId IS NOT NULL AND ReceivedQuantityBase IS NOT NULL
                    GROUP BY PoLineId) x ON x.PoLineId = pol.Id;

        DECLARE @Reopened TABLE (Id INT NOT NULL PRIMARY KEY);
        UPDATE po
        SET Status = 2, ClosedAtUtc = NULL, ClosedBy = NULL, CloseReason = NULL
        OUTPUT inserted.Id INTO @Reopened (Id)
        FROM purchase.PurchaseDocuments po
        WHERE po.Id IN (SELECT PurchaseOrderId FROM logistics.ContainerLines WHERE ContainerId = @Id)
          AND po.Status = 4 AND po.CloseReason = N'Fully invoiced and received'
          AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                      WHERE l.DocumentId = po.Id AND l.GoodsReceivedBase + l.GoodsShortBase < l.QuantityBase);

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT r.Id, N'Updated', LEFT(N'Re-opened: the offload of ' + c.ContainerRef + N' was reversed', 500), @UserId
        FROM @Reopened r CROSS JOIN logistics.Containers c
        WHERE c.Id = @Id;

        UPDATE logistics.ContainerLines
        SET ReceivedQuantityBase = NULL, VarianceReason = NULL, FobCostBase = NULL, LandedCostBase = NULL
        WHERE ContainerId = @Id;

        UPDATE logistics.ContainerCharges SET AppliedAtOffload = 0 WHERE ContainerId = @Id;
        EXEC logistics.usp_Container_ReallocateCharges @Id;

        UPDATE logistics.Containers
        SET OffloadedDate = NULL, OffloadedAtUtc = NULL, OffloadedBy = NULL,
            StatusNote = LEFT(N'Offload reversed: ' + @Reason, 200), UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        EXEC logistics.usp_Container_RefreshStatus @Id;

        DECLARE @ItemId INT;
        DECLARE citems CURSOR LOCAL FAST_FORWARD FOR SELECT ItemId FROM @Items;
        OPEN citems;
        FETCH NEXT FROM citems INTO @ItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC inventory.usp_Item_RebuildCosts @ItemId;
            FETCH NEXT FROM citems INTO @ItemId;
        END
        CLOSE citems;
        DEALLOCATE citems;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'OffloadCancelled', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 13. Close: every received piece invoiced (Close and Reopen under lock) */

-- (65) WHY AN OFFLOADED CONTAINER CANNOT BE CLOSED YET, IN ONE PLACE: Close refuses with it, and the container page and
-- list show it (CloseBlockedReason), so the Close button says why before the click. At most one row: draft charges
-- first (70010), then rule 20 (69016): the first container line, in line order, whose pieces received by posted goods
-- receipts are not all matched to posted invoices. A container offloaded before goods receipts had its posted invoices
-- before the offload: rule 20 does not apply to it. No row: nothing here blocks it (the status is checked apart).
-- No NULL reaches a SUM (a receipt line nothing is matched to counts 0): a NULL inside the SUM raised warning 8153 ("Null
-- value is eliminated by an aggregate"), which SqlClient joined to the 69016 message the user read.
CREATE OR ALTER FUNCTION logistics.fn_Container_CloseBlock (@ContainerId INT)
RETURNS TABLE
AS
RETURN
    SELECT TOP (1) b.ErrorNumber, b.Reason
    FROM (SELECT ErrorNumber = 70010, Ord = 0, LineNumber = 0,
                 Reason = CAST(N'The container still has draft charges. Post or delete them before closing it.' AS NVARCHAR(400))
          WHERE EXISTS (SELECT 1 FROM logistics.ContainerCharges ch WHERE ch.ContainerId = @ContainerId AND ch.Status = 1)
          UNION ALL
          SELECT 69016, 1, cl.LineNumber,
                 CAST(N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                      + CAST(x.Received AS NVARCHAR(20)) + N' received but ' + CAST(x.Invoiced AS NVARCHAR(20))
                      + N' invoiced by posted invoices. Post the supplier invoices before closing the container.' AS NVARCHAR(400))
          FROM logistics.ContainerLines cl
          INNER JOIN inventory.Items i ON i.Id = cl.ItemId
          CROSS APPLY (SELECT Received = ISNULL(SUM(ISNULL(gl.QuantityBase, 0)), 0), Invoiced = ISNULL(SUM(mm.Qty), 0)
                       FROM purchase.GoodsReceiptLines gl
                       INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId AND g.Status = 2
                       CROSS APPLY (SELECT Qty = ISNULL(SUM(m.QuantityBase), 0) FROM purchase.GoodsReceiptInvoiceMatches m
                                    WHERE m.GoodsReceiptLineId = gl.Id) mm
                       WHERE gl.ContainerLineId = cl.Id) x
          WHERE cl.ContainerId = @ContainerId AND x.Invoiced < x.Received
            AND EXISTS (SELECT 1 FROM logistics.fn_Container_ReceivedBy(@ContainerId) r WHERE r.ReceivedBy = N'GRN')) b
    ORDER BY b.Ord, b.LineNumber;
GO

-- Re-created (65) from the body of script 27: a container received with a goods receipt closes only when its received
-- pieces are matched to posted invoices (69016, rule 20).
-- (65) ONE TRANSACTION, THE CONTAINER READ UNDER LOCK (UPDLOCK, HOLDLOCK) BEFORE ANY CHECK: goods receipt Post and
-- Cancel hold the container the same way while they change its status, so Close waits for them and checks what they
-- committed. Read without the lock, a Close that ran during the Cancel of the container's receipt read "Offloaded",
-- waited, then closed a container whose receipt was cancelled (no stock, no offload date, and taken from then on for an
-- offload of the old kind). The write is guarded as well (Status = 6).
CREATE OR ALTER PROCEDURE logistics.usp_Container_Close
    @Id INT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT;
        SELECT @Status = Status FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 69006, 'Container not found.', 1;
        IF @Status <> 6 THROW 69010, 'Only an offloaded container can be closed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
        -- Draft charges (70010), then (65) RULE 20: A CONTAINER RECEIVED WITH A GOODS RECEIPT CLOSES WHEN EVERY RECEIVED
        -- PIECE IS MATCHED TO A POSTED INVOICE (69016: the matches of its receipt's lines, per container line). Goods
        -- may now arrive before their invoice, and a closed container is frozen. An offload of the old kind needed the
        -- posted invoices before it: no check for those. Both from fn_Container_CloseBlock, which the container page and
        -- list read too.
        DECLARE @BlockNumber INT, @Msg NVARCHAR(400);
        SELECT @BlockNumber = b.ErrorNumber, @Msg = b.Reason FROM logistics.fn_Container_CloseBlock(@Id) b;
        IF @BlockNumber = 70010 THROW 70010, @Msg, 1;
        IF @BlockNumber = 69016 THROW 69016, @Msg, 1;

        UPDATE logistics.Containers
        SET Status = 7, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id AND Status = 6;
        IF @@ROWCOUNT = 0 THROW 69010, 'Only an offloaded container can be closed.', 1;
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'Closed', N'Container closed', @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- A closed container is opened again (e.g. a late charge arrives).
-- Re-created (65) from the body of script 27 the way Close is above: one transaction, the container read under lock
-- before the checks, and a guarded write (Status = 7) - the status it checks is the status it changes.
CREATE OR ALTER PROCEDURE logistics.usp_Container_Reopen
    @Id INT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT;
        SELECT @Status = Status FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 69006, 'Container not found.', 1;
        IF @Status <> 7 THROW 69010, 'Only a closed container can be reopened.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM logistics.Containers c
                   INNER JOIN logistics.Containers o ON o.ContainerNo = c.ContainerNo AND o.Id <> c.Id AND o.Status < 7
                   WHERE c.Id = @Id AND c.ContainerNo IS NOT NULL)
            THROW 69013, 'Another open container already uses this container number. Change that one first.', 1;

        UPDATE logistics.Containers
        SET Status = 6, ClosedAtUtc = NULL, ClosedBy = NULL, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id AND Status = 7;
        IF @@ROWCOUNT = 0 THROW 69010, 'Only a closed container can be reopened.', 1;
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'Updated', N'Container reopened', @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 14. Save, Cancel, Delete: a container with a goods receipt */

-- Re-created (65) from the body of script 54: 69019 when a container with an open goods receipt would change its load
-- lines or its branch (rule 21; the header stays editable); what is committed outside containers is
-- purchase.fn_PoLine_CommittedOutside; the lines of CANCELLED goods receipts let go of the container lines removed
-- (as the lines of cancelled invoices do), so a container whose receipt was cancelled can change its lines again.
-- (65) THE CHECKS AND THE WRITE IN ONE TRANSACTION, THE CONTAINER READ UNDER LOCK (UPDLOCK, HOLDLOCK) FIRST: "Receive
-- goods..." and goods receipt Post hold the container the same way before they write, so a save made meanwhile waits
-- and is then refused (69005, 69019). Checked without the lock, it passed while the receipt was being posted, waited,
-- and wrote the form's header over the received container - its warehouse back to the form's (empty) value, which a
-- late charge needs (70010) - or changed the lines of a container whose draft receipt had just been created.
CREATE OR ALTER PROCEDURE logistics.usp_Container_Save
    @Id                  INT            = NULL,   -- NULL = create (ContainerRef assigned now)
    @PurchaseOrderId     INT            = NULL,   -- required on create: the order the container is created from
    @ContainerNo         NVARCHAR(20)   = NULL,
    @ContainerTypeId     INT,
    @SealNo              NVARCHAR(30)   = NULL,
    @CustomsSealNo       NVARCHAR(30)   = NULL,
    @Description         NVARCHAR(500)  = NULL,
    @OrderDate           DATE,
    @ShippingMethod      NVARCHAR(10)   = N'Sea',
    @CountryOfOrigin     NCHAR(2)       = NULL,
    @ForwarderId         INT            = NULL,
    @TransporterId       INT            = NULL,
    @ShippingLine        NVARCHAR(100)  = NULL,
    @VesselName          NVARCHAR(100)  = NULL,
    @VoyageNo            NVARCHAR(30)   = NULL,
    @BookingNo           NVARCHAR(30)   = NULL,
    @PortOfLoadingId     INT            = NULL,
    @PortOfDestinationId INT            = NULL,
    @FinalDestinationId  INT            = NULL,
    @DispatchDate        DATE           = NULL,   -- the four milestone dates are replaced by the movements when there are some
    @Eta                 DATE           = NULL,
    @FreeDays            INT            = NULL,
    @GrossWeightKg       DECIMAL(18,3)  = NULL,
    @VolumeCbm           DECIMAL(18,3)  = NULL,
    @Packages            INT            = NULL,
    @BlNo                NVARCHAR(30)   = NULL,
    @BlDate              DATE           = NULL,
    @BlNotes             NVARCHAR(500)  = NULL,
    @MaxUnits            INT            = NULL,   -- (54) ignored: the capacity is the items' Container units
    @BranchId            INT,
    @WarehouseId         INT            = NULL,
    @TruckNo             NVARCHAR(30)   = NULL,
    @WaybillNo           NVARCHAR(30)   = NULL,
    @DeclarationNo       NVARCHAR(30)   = NULL,
    @FeriNo              NVARCHAR(30)   = NULL,
    @ActualPortArrival   DATE           = NULL,
    @BorderCrossingDate  DATE           = NULL,
    @CustomsReleaseDate  DATE           = NULL,
    @StatusNote          NVARCHAR(200)  = NULL,
    @Notes               NVARCHAR(1000) = NULL,
    @Lines               logistics.tvp_ContainerLoadLine READONLY,
    @AllowOverCapacity   BIT            = 0,
    @RowVersion          BINARY(8)      = NULL,
    @UserId              INT            = NULL,
    @ForInvoiceId        INT            = NULL,   -- (43) for this invoice of the order: the order may be closed by it
    @NewId               INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ContainerNo = UPPER(NULLIF(LTRIM(RTRIM(@ContainerNo)), N''));
    SET @SealNo = NULLIF(LTRIM(RTRIM(@SealNo)), N'');
    SET @CustomsSealNo = NULLIF(LTRIM(RTRIM(@CustomsSealNo)), N'');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @ShippingMethod = NULLIF(LTRIM(RTRIM(@ShippingMethod)), N'');
    SET @BlNo = NULLIF(LTRIM(RTRIM(@BlNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @StatusNote = NULLIF(LTRIM(RTRIM(@StatusNote)), N'');
    IF @ShippingMethod IS NULL SET @ShippingMethod = N'Sea';

    -- (51) a container created for an invoice: the invoice's rules 1-8 first, before anything is created
    IF @ForInvoiceId IS NOT NULL AND @Id IS NULL
    BEGIN
        DECLARE @ForInvoiceQty INT = (SELECT SUM(QuantityBase) FROM @Lines);
        EXEC purchase.usp_PurchaseInvoice_CheckContainers @InvoiceId = @ForInvoiceId, @Action = N'Add', @QuantityBase = @ForInvoiceQty;
    END

    IF @OrderDate IS NULL THROW 69000, 'Order date is required.', 1;
    IF @ShippingMethod NOT IN (N'Sea', N'Air', N'Road') THROW 69000, 'Shipping method must be Sea, Air or Road.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId AND IsActive = 1)
        THROW 69000, 'Container type not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 69000, 'Branch not found or inactive.', 1;
    IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1)
        THROW 69000, 'Offloading warehouse not found or inactive.', 1;
    IF @FreeDays IS NOT NULL AND @FreeDays < 0 THROW 69000, 'Free days cannot be negative.', 1;
    IF @DispatchDate IS NOT NULL AND @Eta IS NOT NULL AND @Eta < @DispatchDate
        THROW 69000, 'The ETA cannot be earlier than the dispatch date.', 1;
    IF @ContainerNo IS NOT NULL AND EXISTS (SELECT 1 FROM logistics.Containers
                                            WHERE ContainerNo = @ContainerNo AND Status < 7 AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'Another open container already uses this container number.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT = NULL;
        IF @Id IS NOT NULL
        BEGIN
            SELECT @Status = Status, @PurchaseOrderId = ISNULL(PurchaseOrderId, @PurchaseOrderId)
            FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
            IF @Status IS NULL THROW 69006, 'Container not found.', 1;
            IF @Status >= 6 THROW 69005, 'An offloaded, closed or cancelled container can no longer be changed.', 1;
            IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
                THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;

            -- (65) RULE 21: A CONTAINER WITH AN OPEN GOODS RECEIPT KEEPS ITS LOAD LINES AND ITS BRANCH (the draft
            -- mirrors the lines, order line by order line, with the loaded pieces; its warehouse must be of the
            -- branch). A posted receipt made the container Offloaded, refused above. The header stays editable (truck,
            -- waybill, declaration, FERI, B/L, free days, notes, warehouse: the draft keeps its own "Receive into"),
            -- and so do a line's oil and notes.
            DECLARE @GrnMsg NVARCHAR(400);
            SELECT @GrnMsg = N'Container ' + c.ContainerRef + N' has ' + ISNULL(N'goods receipt ' + r.GoodsReceiptNumber, N'a draft goods receipt')
                             + N'. Delete the draft (or cancel the receipt) first.'
            FROM logistics.Containers c
            CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) r
            WHERE c.Id = @Id AND r.GoodsReceiptId IS NOT NULL
              AND (c.BranchId <> @BranchId
                   OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                              WHERE cl.ContainerId = @Id
                                AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId AND l.QuantityBase = cl.QuantityBase))
                   OR EXISTS (SELECT 1 FROM @Lines l
                              WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = @Id AND cl.PoLineId = l.PoLineId)));
            IF @GrnMsg IS NOT NULL THROW 69019, @GrnMsg, 1;
        END
        ELSE
        BEGIN
            IF @PurchaseOrderId IS NULL THROW 69000, 'The purchase order is required: a container is created from a purchase order.', 1;
            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                           WHERE d.Id = @PurchaseOrderId AND dt.Code = N'PO'
                             AND (d.Status = 2 OR (d.Status = 4 AND purchase.fn_PurchaseInvoice_TakesContainers(d.Id, @ForInvoiceId) = 1)))
                THROW 69000, 'The purchase order must be approved and still open.', 1;
        END

        DECLARE @Msg NVARCHAR(400);

        IF EXISTS (SELECT PoLineId FROM @Lines GROUP BY PoLineId HAVING COUNT(*) > 1)
            THROW 69000, 'The same order line appears twice in the container.', 1;

        -- Lines: order line of an approved order (lines already loaded may belong to an order closed since), quantity, oil.
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN pol.Id IS NULL OR dt.Code <> N'PO' THEN N'the purchase order line no longer exists.'
                 WHEN l.QuantityBase <= 0 THEN N'the quantity must be greater than zero.'
                 WHEN l.OilQtyPerUnit < 0 THEN N'the oil quantity cannot be negative.'
                 WHEN ex.Id IS NULL AND d.Status <> 2 AND NOT (d.Status = 4 AND purchase.fn_PurchaseInvoice_TakesContainers(d.Id, @ForInvoiceId) = 1) THEN N'order ' + ISNULL(d.DocumentNumber, N'(draft)') + N' is not approved or no longer open.'
                 WHEN ex.Id IS NOT NULL AND d.Status NOT IN (2, 4) THEN N'order ' + ISNULL(d.DocumentNumber, N'(draft)') + N' was cancelled.'
                 ELSE N'item ' + i.ItemCode + N' has no base unit.' END
        FROM @Lines l
        LEFT JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        LEFT JOIN purchase.PurchaseDocuments d       ON d.Id = pol.DocumentId
        LEFT JOIN inventory.DocumentTypes dt         ON dt.Id = d.DocumentTypeId
        LEFT JOIN inventory.Items i                  ON i.Id = pol.ItemId
        LEFT JOIN logistics.ContainerLines ex        ON ex.ContainerId = @Id AND ex.PoLineId = l.PoLineId
        WHERE pol.Id IS NULL OR dt.Code <> N'PO' OR l.QuantityBase <= 0 OR l.OilQtyPerUnit < 0
           OR (ex.Id IS NULL AND d.Status <> 2 AND NOT (d.Status = 4 AND purchase.fn_PurchaseInvoice_TakesContainers(d.Id, @ForInvoiceId) = 1)) OR (ex.Id IS NOT NULL AND d.Status NOT IN (2, 4))
           OR NOT EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.ItemId = pol.ItemId AND u.IsBaseUnit = 1)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

        -- Quantity still loadable on the order line. (65) What the order line committed outside containers is the larger of
        -- what is invoiced and what is received (or on draft receipts) outside containers: the same goods, matched.
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - '
                              + CAST(l.QuantityBase AS NVARCHAR(20)) + N' loaded but only '
                              + CAST(pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) AS NVARCHAR(20))
                              + N' remain on order ' + ISNULL(d.DocumentNumber, N'(draft)') + N' line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N'.'
        FROM @Lines l
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        INNER JOIN purchase.PurchaseDocuments d       ON d.Id = pol.DocumentId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        OUTER APPLY purchase.fn_PoLine_CommittedOutside(pol.Id, NULL) dir
        OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                     INNER JOIN logistics.Containers c2 ON c2.Id = cl.ContainerId
                     WHERE cl.PoLineId = pol.Id AND c2.Status <> 8 AND (@Id IS NULL OR cl.ContainerId <> @Id)) oth
        WHERE l.QuantityBase > pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 69008, @Msg, 1;

        IF @Id IS NOT NULL
        BEGIN
            -- Invoiced lines cannot be removed, nor loaded below what is invoiced.
            SELECT TOP (1) @Msg = N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - '
                                  + CAST(q.Invoiced AS NVARCHAR(20)) + N' already invoiced (' + ISNULL(q.Numbers, N'') + N'); '
                                  + CASE WHEN l.PoLineId IS NULL THEN N'the line cannot be removed.' ELSE N'the quantity cannot be lower.' END
            FROM logistics.ContainerLines cl
            INNER JOIN inventory.Items i ON i.Id = cl.ItemId
            CROSS APPLY (SELECT Invoiced = ISNULL(SUM(pil.QuantityBase), 0), Numbers = STRING_AGG(pd.DocumentNumber, N', ')
                         FROM purchase.PurchaseDocumentLines pil
                         INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                         WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
            LEFT JOIN @Lines l ON l.PoLineId = cl.PoLineId
            WHERE cl.ContainerId = @Id AND q.Invoiced > 0 AND (l.PoLineId IS NULL OR l.QuantityBase < q.Invoiced)
            ORDER BY cl.LineNumber;
            IF @Msg IS NOT NULL THROW 69017, @Msg, 1;

            -- A removed line cannot carry a manual share of a posted charge.
            SELECT TOP (1) @Msg = N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' carries a manual share of the posted charge '
                                  + t.ChargeName + N'. Cancel that charge before removing the line.'
            FROM logistics.ContainerLines cl
            INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id AND a.IsManual = 1
            INNER JOIN logistics.ContainerCharges ch          ON ch.Id = a.ChargeId AND ch.Status = 2
            INNER JOIN purchase.ChargeTypes t                 ON t.Id = ch.ChargeTypeId
            WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId)
            ORDER BY cl.LineNumber;
            IF @Msg IS NOT NULL THROW 70014, @Msg, 1;
        END

        IF @Id IS NULL
        BEGIN
            DECLARE @Ref NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'CNT');
            EXEC inventory.usp_DocumentType_NextNumber N'CNT', @Ref OUTPUT, @BranchId;

            INSERT INTO logistics.Containers (DocumentTypeId, ContainerRef, PurchaseOrderId, ContainerNo, ContainerTypeId, SealNo, CustomsSealNo, Description,
                                              OrderDate, ShippingMethod, CountryOfOrigin, ForwarderId, TransporterId,
                                              ShippingLine, VesselName, VoyageNo, BookingNo, PortOfLoadingId, PortOfDestinationId, FinalDestinationId,
                                              DispatchDate, Eta, FreeDays, GrossWeightKg, VolumeCbm, Packages, BlNo, BlDate, BlNotes,
                                              MaxUnits, BranchId, WarehouseId, TruckNo, WaybillNo, DeclarationNo, FeriNo,
                                              ActualPortArrival, BorderCrossingDate, CustomsReleaseDate, StatusNote, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Ref, @PurchaseOrderId, @ContainerNo, @ContainerTypeId, @SealNo, @CustomsSealNo, @Description,
                    @OrderDate, @ShippingMethod, @CountryOfOrigin, @ForwarderId, @TransporterId,
                    @ShippingLine, @VesselName, @VoyageNo, @BookingNo, @PortOfLoadingId, @PortOfDestinationId, @FinalDestinationId,
                    @DispatchDate, @Eta, @FreeDays, @GrossWeightKg, @VolumeCbm, @Packages, @BlNo, @BlDate, @BlNotes,
                    NULL, @BranchId, @WarehouseId, @TruckNo, @WaybillNo, @DeclarationNo, @FeriNo,
                    @ActualPortArrival, @BorderCrossingDate, @CustomsReleaseDate, @StatusNote, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Id, N'Created', N'Draft ' + @Ref + ISNULL(N' from order ' + (SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @PurchaseOrderId), N''), @UserId);
        END
        ELSE
        BEGIN
            UPDATE logistics.Containers
            SET ContainerNo = @ContainerNo, ContainerTypeId = @ContainerTypeId, SealNo = @SealNo, CustomsSealNo = @CustomsSealNo,
                Description = @Description, OrderDate = @OrderDate, ShippingMethod = @ShippingMethod, CountryOfOrigin = @CountryOfOrigin,
                ForwarderId = @ForwarderId, TransporterId = @TransporterId, ShippingLine = @ShippingLine, VesselName = @VesselName,
                VoyageNo = @VoyageNo, BookingNo = @BookingNo, PortOfLoadingId = @PortOfLoadingId, PortOfDestinationId = @PortOfDestinationId,
                FinalDestinationId = @FinalDestinationId, DispatchDate = @DispatchDate, Eta = @Eta, FreeDays = @FreeDays,
                GrossWeightKg = @GrossWeightKg, VolumeCbm = @VolumeCbm, Packages = @Packages, BlNo = @BlNo, BlDate = @BlDate, BlNotes = @BlNotes,
                BranchId = @BranchId, WarehouseId = @WarehouseId, TruckNo = @TruckNo, WaybillNo = @WaybillNo,
                DeclarationNo = @DeclarationNo, FeriNo = @FeriNo, ActualPortArrival = @ActualPortArrival,
                BorderCrossingDate = @BorderCrossingDate, CustomsReleaseDate = @CustomsReleaseDate, StatusNote = @StatusNote, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        -- Lines are kept per order line: removed ones go (with their charge shares), the others are updated, new ones added.
        -- Lines of CANCELLED invoices let go of the removed container lines.
        UPDATE pil SET ContainerLineId = NULL
        FROM purchase.PurchaseDocumentLines pil
        INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId AND pd.Status = 3
        INNER JOIN logistics.ContainerLines cl   ON cl.Id = pil.ContainerLineId
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId);

        -- (65) LINES OF CANCELLED GOODS RECEIPTS LET GO OF THE REMOVED CONTAINER LINES too (FK_GoodsReceiptLines_ContainerLine):
        -- an open receipt refused the change above (69019); a cancelled one only keeps its history, which still reads in
        -- full (its order line, item, quantities and reason stay on the receipt line).
        UPDATE gl SET ContainerLineId = NULL
        FROM purchase.GoodsReceiptLines gl
        INNER JOIN purchase.GoodsReceipts g    ON g.Id = gl.GoodsReceiptId AND g.Status = 3
        INNER JOIN logistics.ContainerLines cl ON cl.Id = gl.ContainerLineId
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId);

        DELETE a FROM logistics.ContainerChargeAllocations a
        INNER JOIN logistics.ContainerLines cl ON cl.Id = a.ContainerLineId
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId);

        DELETE cl FROM logistics.ContainerLines cl
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId);

        UPDATE cl
        SET LineNumber = l.LineNumber, Quantity = l.QuantityBase, OilIncluded = ISNULL(l.OilIncluded, 0),
            OilQtyPerUnit = CASE WHEN ISNULL(l.OilIncluded, 0) = 1 THEN ISNULL(l.OilQtyPerUnit, i.OilQtyPerUnit) END,
            Notes = NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM logistics.ContainerLines cl
        INNER JOIN @Lines l          ON l.PoLineId = cl.PoLineId
        INNER JOIN inventory.Items i ON i.Id = cl.ItemId
        WHERE cl.ContainerId = @Id;

        INSERT INTO logistics.ContainerLines (ContainerId, LineNumber, PurchaseOrderId, PoLineId, ItemId, ItemUnitId, PackingFormula,
                                              Quantity, OilIncluded, OilQtyPerUnit, Notes)
        SELECT @Id, l.LineNumber, pol.DocumentId, pol.Id, pol.ItemId, bu.Id, 1, l.QuantityBase, ISNULL(l.OilIncluded, 0),
               CASE WHEN ISNULL(l.OilIncluded, 0) = 1 THEN ISNULL(l.OilQtyPerUnit, i.OilQtyPerUnit) END,
               NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM @Lines l
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        CROSS APPLY (SELECT TOP (1) u.Id FROM inventory.ItemUnits u WHERE u.ItemId = pol.ItemId AND u.IsBaseUnit = 1 ORDER BY u.Id) bu
        WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = @Id AND cl.PoLineId = l.PoLineId);

        -- (54) Capacity from the items' Container units (logistics.fn_ContainerFill): a warning the caller can override,
        -- never a hard block; unknown (an item without a Container unit) = no warning. Checked on the lines just written,
        -- so the refusal rolls the whole save back.
        IF ISNULL(@AllowOverCapacity, 0) = 0 AND EXISTS (SELECT 1 FROM logistics.fn_ContainerFill(@Id) f WHERE f.IsOverCapacity = 1)
        BEGIN
            -- %% : THROW reads a single % as a format specification ("% f" would swallow the sign and the f).
            SELECT @Msg = LEFT(N'This container would be ' + CAST(CAST(ROUND(f.FillPct, 0) AS INT) AS NVARCHAR(10)) + N' %% full: '
                               + x.Parts + N'. Confirm to load it above its capacity.', 400)
            FROM logistics.fn_ContainerFill(@Id) f
            CROSS APPLY (SELECT Parts = STRING_AGG(CAST(q.Qty AS NVARCHAR(20)) + N' pcs of ' + q.ItemCode + N' ('
                                                   + CAST(q.Pcs AS NVARCHAR(20)) + N' per container)', N', ')
                                        WITHIN GROUP (ORDER BY q.ItemCode)
                         FROM (SELECT i.ItemCode, Qty = SUM(cl.QuantityBase), Pcs = p.PcsPerContainer
                               FROM logistics.ContainerLines cl
                               INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                               CROSS APPLY logistics.fn_ItemPcsPerContainer(cl.ItemId) p
                               WHERE cl.ContainerId = @Id
                               GROUP BY i.ItemCode, p.PcsPerContainer) q) x;
            THROW 69007, @Msg, 1;
        END

        EXEC logistics.usp_Container_ReallocateCharges @Id;
        EXEC logistics.usp_Container_RefreshStatus @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (65) from the body of script 27: + 69019 while the container has an open goods receipt (rule 21).
-- (65) ONE TRANSACTION, THE CONTAINER READ UNDER LOCK (UPDLOCK, HOLDLOCK) BEFORE ANY CHECK - the lock "Receive
-- goods..." (usp_GoodsReceipt_CreateForContainer) and goods receipt Post take before they write. Checked without it
-- (and without a transaction), a draft receipt created between the checks and the update was left on a cancelled
-- container. The write is guarded as well (Status < 6).
CREATE OR ALTER PROCEDURE logistics.usp_Container_Cancel
    @Id INT, @Reason NVARCHAR(300), @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 69000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT;
        SELECT @Status = Status FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 69006, 'Container not found.', 1;

        -- (65) RULE 21: NOT WHILE THE CONTAINER HAS AN OPEN GOODS RECEIPT - a draft (to delete) or the posted one (to
        -- cancel, which gives the container its movement status back)
        DECLARE @GrnMsg NVARCHAR(400);
        SELECT @GrnMsg = N'Container ' + c.ContainerRef + N' has ' + ISNULL(N'goods receipt ' + r.GoodsReceiptNumber, N'a draft goods receipt')
                         + N'. Delete the draft (or cancel the receipt) first.'
        FROM logistics.Containers c
        CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) r
        WHERE c.Id = @Id AND r.GoodsReceiptId IS NOT NULL;
        IF @GrnMsg IS NOT NULL THROW 69019, @GrnMsg, 1;

        IF @Status >= 6 THROW 69010, 'An offloaded, closed or cancelled container cannot be cancelled. Reverse the offload first.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;

        DECLARE @Msg NVARCHAR(400);
        IF EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                   INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                   INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                   WHERE cl.ContainerId = @Id AND d.Status <> 3)
        BEGIN
            SELECT TOP (1) @Msg = N'The container is invoiced by ' + ISNULL(d.DocumentNumber, N'a draft invoice') + N'. Cancel or delete its invoices first.'
            FROM logistics.ContainerLines cl
            INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
            INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
            WHERE cl.ContainerId = @Id AND d.Status <> 3
            ORDER BY d.Status DESC, d.DocumentNumber;
            THROW 69012, @Msg, 1;
        END
        IF EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE ContainerId = @Id AND Status IN (1, 2))
            THROW 70014, 'The container has charges. Delete the drafts and cancel the posted ones first.', 1;
        SELECT TOP (1) @Msg = N'The container is part of movement ' + m.MovementNo + N'. Remove it from that movement first.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
        WHERE mc.ContainerId = @Id AND m.Status IN (1, 2)
        ORDER BY m.MovementNo;
        IF @Msg IS NOT NULL THROW 70012, @Msg, 1;

        UPDATE logistics.Containers
        SET Status = 8, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id AND Status < 6;
        IF @@ROWCOUNT = 0 THROW 69010, 'An offloaded, closed or cancelled container cannot be cancelled. Reverse the offload first.', 1;
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (65) from the body of script 27: + 69019 while the container has an open goods receipt (rule 21).
CREATE OR ALTER PROCEDURE logistics.usp_Container_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @Id);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;

    -- (65) RULE 21: NOT WHILE THE CONTAINER HAS AN OPEN GOODS RECEIPT. A draft container never has one (a receipt needs
    -- a confirmed container): the check states the rule here as Cancel and Save do, in their words.
    DECLARE @GrnMsg NVARCHAR(400);
    SELECT @GrnMsg = N'Container ' + c.ContainerRef + N' has ' + ISNULL(N'goods receipt ' + r.GoodsReceiptNumber, N'a draft goods receipt')
                     + N'. Delete the draft (or cancel the receipt) first.'
    FROM logistics.Containers c
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) r
    WHERE c.Id = @Id AND r.GoodsReceiptId IS NOT NULL;
    IF @GrnMsg IS NOT NULL THROW 69019, @GrnMsg, 1;

    IF @Status <> 1 THROW 69005, 'Only a draft container can be deleted. Cancel the others.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerLines cl
               INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
               INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
               WHERE cl.ContainerId = @Id AND d.Status <> 3)
        THROW 69012, 'The container is invoiced. Cancel or delete its invoices first.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE ContainerId = @Id AND Status IN (2, 3))
        THROW 70014, 'Posted or cancelled charges refer to this container. Cancel the container instead.', 1;
    IF EXISTS (SELECT 1 FROM logistics.MovementContainers mc INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
               WHERE mc.ContainerId = @Id AND m.Status IN (2, 3))
        THROW 70012, 'The container already travelled with a movement. Cancel the container instead.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @Files TABLE (FileId INT PRIMARY KEY);
        INSERT INTO @Files (FileId) SELECT DISTINCT FileId FROM logistics.ContainerAttachments WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerAttachments WHERE ContainerId = @Id;
        DELETE f FROM logistics.Files f INNER JOIN @Files x ON x.FileId = f.Id
        WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerAttachments a WHERE a.FileId = f.Id);

        UPDATE pil SET ContainerLineId = NULL                  -- lines of cancelled invoices
        FROM purchase.PurchaseDocumentLines pil
        INNER JOIN logistics.ContainerLines cl ON cl.Id = pil.ContainerLineId
        WHERE cl.ContainerId = @Id;

        DELETE a FROM logistics.ContainerChargeAllocations a INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId WHERE ch.ContainerId = @Id;
        DELETE FROM logistics.ContainerCharges WHERE ContainerId = @Id;
        DELETE FROM logistics.MovementContainers WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerLines WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerAudit WHERE ContainerId = @Id;
        DELETE FROM logistics.Containers WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 15. What can still be loaded into containers: committed outside = invoiced or received */

-- Re-created (65) from the body of script 54: what an order line has committed OUTSIDE containers is
-- purchase.fn_PoLine_CommittedOutside - the larger of what is invoiced and what is received (or on draft goods
-- receipts) outside containers - in place of the "dir" subquery (invoiced only). Goods received from the order without a
-- container are no longer proposed again in containers (edge case 17). The rest is the body of script 54: pieces per
-- container = the item's Container unit only (logistics.fn_ItemPcsPerContainer); @Capacities and the container type's
-- MaxUnits are no longer read; an item without a Container unit stops the plan (69000).
CREATE OR ALTER PROCEDURE logistics.usp_Container_PlanFromOrder
    @PurchaseOrderId INT,
    @ContainerTypeId INT,
    @MixRemainders   BIT = 1,       -- 0 = the rest of every order line gets its own container
    @Capacities      logistics.tvp_ItemCapacity READONLY,    -- (54) ignored: the items' Container units only
    @ForInvoiceId    INT = NULL      -- (43) only what this invoice of the order has outside containers
AS
BEGIN
    SET NOCOUNT ON;

    -- (51) a proposal for an invoice: the invoice's rules 1-7 first
    IF @ForInvoiceId IS NOT NULL EXEC purchase.usp_PurchaseInvoice_CheckContainers @InvoiceId = @ForInvoiceId, @Action = N'Plan';

    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                   WHERE d.Id = @PurchaseOrderId AND dt.Code = N'PO'
                     AND (d.Status = 2 OR (d.Status = 4 AND purchase.fn_PurchaseInvoice_TakesContainers(d.Id, @ForInvoiceId) = 1)))
        THROW 69000, 'The purchase order must be approved and still open.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId AND IsActive = 1)
        THROW 69000, 'Container type not found or inactive.', 1;
    DECLARE @Msg NVARCHAR(400);

    -- order lines: what can still be loaded (ordered - committed outside containers - loaded in other containers).
    -- (65) Committed outside = MAX(invoiced outside containers, received + on draft receipts outside containers): an
    -- invoiced piece and a received piece outside containers are the same goods (they are matched), never added up.
    DECLARE @Lines TABLE
    (
        PoLineId      INT          NOT NULL PRIMARY KEY,
        PoLineNumber  INT          NOT NULL,
        ItemId        INT          NOT NULL,
        OrderedBase   INT          NOT NULL,
        AvailableBase INT          NOT NULL,
        Cap           INT          NULL,
        CapSource     NVARCHAR(20) NOT NULL,     -- (54) Item Definition | None
        OilIncluded   BIT          NOT NULL,
        Remaining     INT          NOT NULL
    );
    INSERT INTO @Lines (PoLineId, PoLineNumber, ItemId, OrderedBase, AvailableBase, Cap, CapSource, OilIncluded, Remaining)
    SELECT l.Id, l.LineNumber, l.ItemId, l.QuantityBase,
           CASE WHEN @ForInvoiceId IS NOT NULL AND inv.UnlinkedBase < l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0)
                THEN inv.UnlinkedBase
                ELSE l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) END,
           cnt.PcsPerContainer,
           CASE WHEN cnt.PcsPerContainer IS NOT NULL THEN N'Item Definition' ELSE N'None' END,
           CASE WHEN i.OilQtyPerUnit > 0 THEN 1 ELSE 0 END,
           0
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    LEFT  JOIN purchase.fn_PurchaseInvoice_Unlinked(@ForInvoiceId) inv ON inv.PoLineId = l.Id
    OUTER APPLY purchase.fn_PoLine_CommittedOutside(l.Id, NULL) dir
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8) oth
    CROSS APPLY logistics.fn_ItemPcsPerContainer(l.ItemId) cnt
    WHERE l.DocumentId = @PurchaseOrderId AND (@ForInvoiceId IS NULL OR inv.UnlinkedBase > 0);

    SELECT TOP (1) @Msg = N'Line ' + CAST(l.PoLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): set its Container unit in Item Definition first.'
    FROM @Lines l INNER JOIN inventory.Items i ON i.Id = l.ItemId
    WHERE l.AvailableBase > 0 AND l.Cap IS NULL
    ORDER BY l.PoLineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

    IF (SELECT SUM(AvailableBase / Cap) FROM @Lines WHERE AvailableBase > 0) > 200
        THROW 69000, 'The plan would need more than 200 containers. Check the pieces per container, or plan the order in parts.', 1;

    DECLARE @Plan TABLE (Seq INT NOT NULL, PoLineId INT NOT NULL, QuantityBase INT NOT NULL, PRIMARY KEY (Seq, PoLineId));
    DECLARE @Seq INT = 0, @PoLineId INT, @Avail INT, @Cap INT, @Full INT, @k INT, @Rem INT;

    -- a. whole containers of one item
    DECLARE full_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
        SELECT PoLineId, AvailableBase, Cap FROM @Lines WHERE AvailableBase > 0 ORDER BY PoLineNumber;
    OPEN full_cur;
    FETCH NEXT FROM full_cur INTO @PoLineId, @Avail, @Cap;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Full = @Avail / @Cap;
        SET @k = 0;
        WHILE @k < @Full
        BEGIN
            SET @k = @k + 1;
            SET @Seq = @Seq + 1;
            INSERT INTO @Plan (Seq, PoLineId, QuantityBase) VALUES (@Seq, @PoLineId, @Cap);
        END
        UPDATE @Lines SET Remaining = @Avail - @Full * @Cap WHERE PoLineId = @PoLineId;
        FETCH NEXT FROM full_cur INTO @PoLineId, @Avail, @Cap;
    END
    CLOSE full_cur;
    DEALLOCATE full_cur;

    -- b. the rest of every line
    DECLARE @FirstRest INT = @Seq;
    IF ISNULL(@MixRemainders, 1) = 0
    BEGIN
        INSERT INTO @Plan (Seq, PoLineId, QuantityBase)
        SELECT @FirstRest + ROW_NUMBER() OVER (ORDER BY PoLineNumber), PoLineId, Remaining
        FROM @Lines WHERE Remaining > 0;
    END
    ELSE
    BEGIN
        DECLARE @Bins TABLE (Seq INT NOT NULL PRIMARY KEY, Used DECIMAL(38,20) NOT NULL);
        DECLARE @RestA TABLE (Seq INT NOT NULL, PoLineId INT NOT NULL, QuantityBase INT NOT NULL, PRIMARY KEY (Seq, PoLineId));
        DECLARE @RestB TABLE (Seq INT NOT NULL, PoLineId INT NOT NULL, QuantityBase INT NOT NULL, PRIMARY KEY (Seq, PoLineId));
        DECLARE @Frac DECIMAL(38,20), @Bin INT, @Need INT;

        -- first fit, largest first, a line is never cut
        DECLARE ffd_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT PoLineId, Remaining, Cap FROM @Lines WHERE Remaining > 0
            ORDER BY CAST(Remaining AS DECIMAL(38,20)) / Cap DESC, PoLineNumber;
        OPEN ffd_cur;
        FETCH NEXT FROM ffd_cur INTO @PoLineId, @Rem, @Cap;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Frac = CAST(@Rem AS DECIMAL(38,20)) / @Cap;
            SET @Bin = NULL;
            SELECT TOP (1) @Bin = Seq FROM @Bins WHERE Used + @Frac <= 1.000001 ORDER BY Seq;
            IF @Bin IS NULL
            BEGIN
                SET @Bin = @FirstRest + 1 + (SELECT COUNT(*) FROM @Bins);
                INSERT INTO @Bins (Seq, Used) VALUES (@Bin, 0);
            END
            UPDATE @Bins SET Used = Used + @Frac WHERE Seq = @Bin;
            INSERT INTO @RestA (Seq, PoLineId, QuantityBase) VALUES (@Bin, @PoLineId, @Rem);
            FETCH NEXT FROM ffd_cur INTO @PoLineId, @Rem, @Cap;
        END
        CLOSE ffd_cur;
        DEALLOCATE ffd_cur;

        SET @Need = CEILING((SELECT SUM(CAST(Remaining AS DECIMAL(38,20)) / Cap) FROM @Lines WHERE Remaining > 0) - 0.000001);

        IF (SELECT COUNT(*) FROM @Bins) > @Need
        BEGIN
            -- cutting lines saves containers: fill every container to the brim, a line goes on in the next container
            DECLARE @Used DECIMAL(38,20) = 0, @Open BIT = 0, @Fits INT, @Take INT, @SeqB INT = @FirstRest;
            DECLARE nf_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
                SELECT PoLineId, Remaining, Cap FROM @Lines WHERE Remaining > 0
                ORDER BY CAST(Remaining AS DECIMAL(38,20)) / Cap DESC, PoLineNumber;
            OPEN nf_cur;
            FETCH NEXT FROM nf_cur INTO @PoLineId, @Rem, @Cap;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                WHILE @Rem > 0
                BEGIN
                    IF @Open = 0
                    BEGIN
                        SET @SeqB = @SeqB + 1;
                        SET @Used = 0;
                        SET @Open = 1;
                    END
                    SET @Fits = FLOOR((1 - @Used) * @Cap + 0.000001);
                    IF @Fits <= 0
                        SET @Open = 0;
                    ELSE
                    BEGIN
                        SET @Take = CASE WHEN @Rem < @Fits THEN @Rem ELSE @Fits END;
                        INSERT INTO @RestB (Seq, PoLineId, QuantityBase) VALUES (@SeqB, @PoLineId, @Take);
                        SET @Used = @Used + CAST(@Take AS DECIMAL(38,20)) / @Cap;
                        SET @Rem = @Rem - @Take;
                        IF @Rem > 0 OR @Used >= 0.999999 SET @Open = 0;   -- a cut line goes on in the next container
                    END
                END
                FETCH NEXT FROM nf_cur INTO @PoLineId, @Rem, @Cap;
            END
            CLOSE nf_cur;
            DEALLOCATE nf_cur;
        END

        IF EXISTS (SELECT 1 FROM @RestB) AND (SELECT COUNT(DISTINCT Seq) FROM @RestB) < (SELECT COUNT(*) FROM @Bins)
            INSERT INTO @Plan (Seq, PoLineId, QuantityBase) SELECT Seq, PoLineId, QuantityBase FROM @RestB;
        ELSE
            INSERT INTO @Plan (Seq, PoLineId, QuantityBase) SELECT Seq, PoLineId, QuantityBase FROM @RestA;
    END

    IF (SELECT COUNT(DISTINCT Seq) FROM @Plan) > 200
        THROW 69000, 'The plan would need more than 200 containers. Check the pieces per container, or plan the order in parts.', 1;

    -- 1: containers, with their fill from the items' Container units (no MaxUnits any more, script 54).
    SELECT x.Seq, x.ItemCount, x.Units,
           FillPct  = CAST(ROUND(100 * x.Fill, 1) AS DECIMAL(9,1)),
           ItemSummary = CASE WHEN x.ItemCount = 1 THEN x.FirstItem ELSE N'Mixed - ' + CAST(x.ItemCount AS NVARCHAR(10)) + N' items' END
    FROM (SELECT p.Seq,
                 ItemCount = COUNT(DISTINCT l.ItemId),
                 Units     = SUM(p.QuantityBase),
                 Fill      = SUM(CAST(p.QuantityBase AS DECIMAL(38,20)) / l.Cap),
                 FirstItem = MIN(i.ItemCode)
          FROM @Plan p
          INNER JOIN @Lines l          ON l.PoLineId = p.PoLineId
          INNER JOIN inventory.Items i ON i.Id = l.ItemId
          GROUP BY p.Seq) x
    ORDER BY x.Seq;

    -- 2: lines of every container
    SELECT p.Seq,
           LineNumber = ROW_NUMBER() OVER (PARTITION BY p.Seq ORDER BY l.PoLineNumber),
           p.PoLineId, l.PoLineNumber, l.ItemId, i.ItemCode, i.ItemName, i.Model, p.QuantityBase,
           PcsPerContainer = l.Cap, l.OilIncluded, i.OilQtyPerUnit
    FROM @Plan p
    INNER JOIN @Lines l          ON l.PoLineId = p.PoLineId
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    ORDER BY p.Seq, l.PoLineNumber;

    -- 3: order lines
    SELECT l.PoLineId, l.PoLineNumber, l.ItemId, i.ItemCode, i.ItemName, i.Model,
           l.OrderedBase,
           AvailableBase    = CASE WHEN l.AvailableBase > 0 THEN l.AvailableBase ELSE 0 END,
           PlannedBase      = ISNULL(pl.Qty, 0),
           PcsPerContainer  = l.Cap,
           CapacitySource   = l.CapSource,
           ContainersNeeded = CAST(CASE WHEN l.AvailableBase > 0 THEN CAST(l.AvailableBase AS DECIMAL(19,4)) / NULLIF(l.Cap, 0) ELSE 0 END AS DECIMAL(9,2)),
           l.OilIncluded
    FROM @Lines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    OUTER APPLY (SELECT Qty = SUM(p.QuantityBase) FROM @Plan p WHERE p.PoLineId = l.PoLineId) pl
    ORDER BY l.PoLineNumber;
END
GO

-- Re-created (65) from the body of script 54: the whole plan must fit in what the order lines still allow, where what
-- an order line committed outside containers is purchase.fn_PoLine_CommittedOutside (invoiced, or received / on draft
-- goods receipts, outside containers: the larger) in place of the "dir" subquery (invoiced only) - 69008. The rest is
-- the body of script 54: pieces per container = the item's Container unit only; an item without one stops the batch
-- (69000); the containers get no MaxUnits; the answer gives their fill.
CREATE OR ALTER PROCEDURE logistics.usp_Container_CreateBatch
    @PurchaseOrderId     INT,
    @ContainerTypeId     INT,
    @OrderDate           DATE           = NULL,   -- NULL = today
    @BranchId            INT            = NULL,   -- NULL = the order's branch
    @WarehouseId         INT            = NULL,   -- NULL = the order's warehouse (offloading destination)
    @ShippingMethod      NVARCHAR(10)   = N'Sea',
    @CountryOfOrigin     NCHAR(2)       = NULL,
    @ForwarderId         INT            = NULL,
    @ShippingLine        NVARCHAR(100)  = NULL,
    @PortOfLoadingId     INT            = NULL,
    @PortOfDestinationId INT            = NULL,
    @FinalDestinationId  INT            = NULL,
    @Eta                 DATE           = NULL,
    @FreeDays            INT            = NULL,
    @Plan                logistics.tvp_ContainerPlanLine READONLY,
    @Capacities          logistics.tvp_ItemCapacity READONLY,     -- (54) ignored: the items' Container units only
    @AllowOverCapacity   BIT            = 0,
    @Confirm             BIT            = 0,                      -- 1 = the new containers are confirmed at once
    @UserId              INT            = NULL,
    @ForInvoiceId        INT            = NULL                    -- (43) for this invoice: its pieces outside containers at most
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @OrderDate IS NULL SET @OrderDate = CAST(SYSUTCDATETIME() AS DATE);

    -- (51) containers created for an invoice: the invoice's rules 1-8 first, for the whole plan
    IF @ForInvoiceId IS NOT NULL
    BEGIN
        DECLARE @ForInvoiceQty INT = (SELECT SUM(QuantityBase) FROM @Plan);
        EXEC purchase.usp_PurchaseInvoice_CheckContainers @InvoiceId = @ForInvoiceId, @Action = N'Add', @QuantityBase = @ForInvoiceQty;
    END

    DECLARE @OrderBranch INT, @OrderWarehouse INT, @OrderNo NVARCHAR(30);
    SELECT @OrderBranch = d.BranchId, @OrderWarehouse = d.WarehouseId, @OrderNo = d.DocumentNumber
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE d.Id = @PurchaseOrderId AND dt.Code = N'PO' AND (d.Status = 2 OR (d.Status = 4 AND purchase.fn_PurchaseInvoice_TakesContainers(d.Id, @ForInvoiceId) = 1));
    IF @OrderBranch IS NULL THROW 69000, 'The purchase order must be approved and still open.', 1;
    SET @BranchId = ISNULL(@BranchId, @OrderBranch);
    SET @WarehouseId = ISNULL(@WarehouseId, @OrderWarehouse);

    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId AND IsActive = 1)
        THROW 69000, 'Container type not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Plan) THROW 69009, 'The plan has no container to create.', 1;
    IF EXISTS (SELECT 1 FROM @Plan WHERE Seq < 1 OR QuantityBase <= 0)
        THROW 69000, 'Every planned quantity must be greater than zero.', 1;
    IF (SELECT COUNT(DISTINCT Seq) FROM @Plan) > 200
        THROW 69000, 'At most 200 containers can be created at once.', 1;

    DECLARE @Msg NVARCHAR(400);
    IF EXISTS (SELECT 1 FROM @Plan p LEFT JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId
               WHERE pol.Id IS NULL OR pol.DocumentId <> @PurchaseOrderId)
    BEGIN
        SET @Msg = N'A planned line is not a line of order ' + ISNULL(@OrderNo, N'(draft)') + N'. Propose the plan again.';
        THROW 69000, @Msg, 1;
    END

    -- (54) every planned item has a Container unit, as the proposal requires
    SELECT TOP (1) @Msg = N'Line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): set its Container unit in Item Definition first.'
    FROM @Plan p
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId
    INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
    CROSS APPLY logistics.fn_ItemPcsPerContainer(pol.ItemId) cnt
    WHERE cnt.PcsPerContainer IS NULL
    ORDER BY pol.LineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

    -- containers in plan order
    DECLARE @Seqs TABLE (Seq INT NOT NULL PRIMARY KEY, Ord INT NOT NULL);
    INSERT INTO @Seqs (Seq, Ord)
    SELECT x.Seq, ROW_NUMBER() OVER (ORDER BY x.Seq) FROM (SELECT DISTINCT Seq FROM @Plan) x;

    DECLARE @Created TABLE (Seq INT NOT NULL PRIMARY KEY, ContainerId INT NOT NULL);
    DECLARE @L logistics.tvp_ContainerLoadLine;
    DECLARE @Total INT = (SELECT COUNT(*) FROM @Seqs), @Ord INT = NULL, @Seq INT, @NewId INT, @Lock INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- one plan at a time for an order
        SELECT @Lock = Id FROM purchase.PurchaseDocuments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @PurchaseOrderId;

        -- the whole plan must fit in what the order lines still allow. (65) Committed outside containers = the larger of
        -- invoiced and received (or on draft goods receipts) outside containers.
        SELECT TOP (1) @Msg = N'Order line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                            + CAST(t.Planned AS NVARCHAR(20)) + N' pieces planned but only '
                            + CAST(pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) AS NVARCHAR(20))
                            + N' can still be loaded.'
        FROM (SELECT PoLineId, Planned = SUM(QuantityBase) FROM @Plan GROUP BY PoLineId) t
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = t.PoLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        OUTER APPLY purchase.fn_PoLine_CommittedOutside(pol.Id, NULL) dir
        OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                     INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                     WHERE cl.PoLineId = pol.Id AND c.Status <> 8) oth
        WHERE t.Planned > pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0)
        ORDER BY pol.LineNumber;
        IF @Msg IS NOT NULL THROW 69008, @Msg, 1;

        -- (43) for an invoice: no more than its pieces of every order line outside containers
        IF @ForInvoiceId IS NOT NULL
        BEGIN
            SELECT TOP (1) @Msg = N'Order line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                + CAST(t.Planned AS NVARCHAR(20)) + N' pieces planned but the invoice has only '
                                + CAST(ISNULL(inv.UnlinkedBase, 0) AS NVARCHAR(20)) + N' outside containers.'
            FROM (SELECT PoLineId, Planned = SUM(QuantityBase) FROM @Plan GROUP BY PoLineId) t
            INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = t.PoLineId
            INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
            LEFT  JOIN purchase.fn_PurchaseInvoice_Unlinked(@ForInvoiceId) inv ON inv.PoLineId = t.PoLineId
            WHERE t.Planned > ISNULL(inv.UnlinkedBase, 0)
            ORDER BY pol.LineNumber;
            IF @Msg IS NOT NULL THROW 69008, @Msg, 1;
        END

        DECLARE plan_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT Seq, Ord FROM @Seqs ORDER BY Ord;
        OPEN plan_cur;
        FETCH NEXT FROM plan_cur INTO @Seq, @Ord;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DELETE FROM @L;
            INSERT INTO @L (LineNumber, PoLineId, QuantityBase, OilIncluded, OilQtyPerUnit, Notes)
            SELECT ROW_NUMBER() OVER (ORDER BY pol.LineNumber), p.PoLineId, p.QuantityBase,
                   ISNULL(p.OilIncluded, CASE WHEN i.OilQtyPerUnit > 0 THEN 1 ELSE 0 END), NULL, NULL
            FROM @Plan p
            INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId
            INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
            WHERE p.Seq = @Seq;

            SET @NewId = NULL;
            EXEC logistics.usp_Container_Save
                 @PurchaseOrderId     = @PurchaseOrderId,
                 @ContainerTypeId     = @ContainerTypeId,
                 @OrderDate           = @OrderDate,
                 @ShippingMethod      = @ShippingMethod,
                 @CountryOfOrigin     = @CountryOfOrigin,
                 @ForwarderId         = @ForwarderId,
                 @ShippingLine        = @ShippingLine,
                 @PortOfLoadingId     = @PortOfLoadingId,
                 @PortOfDestinationId = @PortOfDestinationId,
                 @FinalDestinationId  = @FinalDestinationId,
                 @Eta                 = @Eta,
                 @FreeDays            = @FreeDays,
                 @BranchId            = @BranchId,
                 @WarehouseId         = @WarehouseId,
                 @Lines               = @L,
                 @AllowOverCapacity   = @AllowOverCapacity,
                 @UserId              = @UserId,
                 @ForInvoiceId        = @ForInvoiceId,
                 @NewId               = @NewId OUTPUT;

            IF ISNULL(@Confirm, 0) = 1
                EXEC logistics.usp_Container_Confirm @Id = @NewId, @UserId = @UserId;

            INSERT INTO @Created (Seq, ContainerId) VALUES (@Seq, @NewId);
            FETCH NEXT FROM plan_cur INTO @Seq, @Ord;
        END
        CLOSE plan_cur;
        DEALLOCATE plan_cur;
        SET @Ord = NULL;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrNo INT = ERROR_NUMBER(), @ErrMsg NVARCHAR(2048) = ERROR_MESSAGE();
        IF @ErrNo >= 50000 AND @Ord IS NOT NULL
        BEGIN
            SET @ErrMsg = LEFT(N'Container ' + CAST(@Seq AS NVARCHAR(10)) + N' of ' + CAST(@Total AS NVARCHAR(10)) + N': ' + @ErrMsg, 2048);
            THROW @ErrNo, @ErrMsg, 1;
        END;
        THROW;
    END CATCH

    SELECT x.Seq, c.Id AS ContainerId, c.ContainerRef, c.Status, c.TotalLines, c.TotalAllocatedBase,
           fl.FillPct, fl.CapacityKnown, fl.IsOverCapacity,
           c.RowVersion
    FROM @Created x
    INNER JOIN logistics.Containers c ON c.Id = x.ContainerId
    CROSS APPLY logistics.fn_ContainerFill(c.Id) fl
    ORDER BY x.Seq;
END
GO

-- Re-created (65) from the body of script 54: what an order line committed outside containers is
-- purchase.fn_PoLine_CommittedOutside (invoiced, or received / on draft goods receipts, outside containers: the larger)
-- in place of the "dir" subquery (invoiced only). InvoicedDirectBase keeps its name and its place in the sums
-- (Ordered - InvoicedDirect - LoadedElsewhere = MaxHere) and now holds that larger figure; its parts follow at the end:
-- InvoicedOutsideBase (the old meaning), ReceivedOutsideBase, InDraftReceiptsOutsideBase.
-- (54) PcPerContainer from logistics.fn_ItemPcsPerContainer (the one place).
CREATE OR ALTER PROCEDURE logistics.usp_Container_AvailablePoLines
    @PurchaseOrderId INT           = NULL,
    @SupplierId      INT           = NULL,
    @Search          NVARCHAR(100) = NULL,    -- order number, item code or name
    @ContainerId     INT           = NULL,
    @Top             INT           = 200
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @Top IS NULL OR @Top < 1 SET @Top = 200;

    SELECT TOP (@Top)
           d.Id AS PurchaseOrderId, d.DocumentNumber AS PurchaseOrderNumber, d.DocumentDate AS OrderDate, d.Status AS OrderStatus,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, cur.CurrencyCode, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           l.Id AS PoLineId, l.LineNumber AS PoLineNumber, l.ItemId, i.ItemCode, i.ItemName, i.Model, br.BrandName,
           l.ItemUnitId, ut.UnitTypeName, l.PackingFormula, l.Quantity AS OrderedQuantity,
           OrderedBase         = l.QuantityBase,
           InvoicedDirectBase  = ISNULL(dir.Qty, 0),
           LoadedElsewhereBase = ISNULL(oth.Qty, 0),
           LoadedHereBase      = ISNULL(here.Qty, 0),
           MaxHereBase         = l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0),
           AvailableBase       = l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) - ISNULL(here.Qty, 0),
           l.UnitPrice, l.DiscountPercent,
           UnitValueBase = l.LineTotal / d.ExchangeRate / NULLIF(l.QuantityBase, 0),
           ItemOilQtyPerUnit = i.OilQtyPerUnit,
           PcPerContainer = cnt.PcsPerContainer,
           i.WeightKg, i.VolumeCbm,
           -- (65) the parts of InvoicedDirectBase (= the larger of invoiced, and received + on draft receipts, outside containers)
           InvoicedOutsideBase        = ISNULL(dir.InvoicedOutsideBase, 0),
           ReceivedOutsideBase        = ISNULL(dir.ReceivedOutsideBase, 0),
           InDraftReceiptsOutsideBase = ISNULL(dir.InDraftReceiptsOutsideBase, 0)
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies cur    ON cur.Id = d.CurrencyId
    INNER JOIN masterdata.Warehouses w      ON w.Id = d.WarehouseId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN masterdata.Brands br         ON br.Id = i.BrandId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    OUTER APPLY purchase.fn_PoLine_CommittedOutside(l.Id, NULL) dir
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8 AND (@ContainerId IS NULL OR cl.ContainerId <> @ContainerId)) oth
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 WHERE cl.PoLineId = l.Id AND cl.ContainerId = @ContainerId) here
    CROSS APPLY logistics.fn_ItemPcsPerContainer(l.ItemId) cnt
    WHERE dt.Code = N'PO' AND d.Status = 2
      AND (@PurchaseOrderId IS NULL OR d.Id = @PurchaseOrderId)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR i.ItemCode LIKE N'%' + @Search + N'%'
           OR i.ItemName LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%')
      AND (l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) - ISNULL(here.Qty, 0) > 0 OR ISNULL(here.Qty, 0) > 0)
    ORDER BY d.DocumentDate DESC, d.Id DESC, l.LineNumber;
END
GO

-- Re-created (65) from the body of script 63:
--   - what each order line still allows: what the order line committed outside containers is
--     purchase.fn_PoLine_CommittedOutside(order line, this invoice) - the larger of what the OTHER invoices invoiced and
--     what is received (or on draft goods receipts) outside containers - in place of the "dir" subquery (invoiced only);
--   - rule 4 on an invoice posted after the switch (UsesGoodsReceipts = 1) without "Shipped in containers": its goods
--     are received with Receive goods..., not with containers (the old sentence stays for invoices posted before); the
--     draft's hint no longer names the retired container offload, and rule 7 names the received pieces too;
--   - rule 6 also when a GOODS RECEIPT refers to the invoice's lines outside containers (rule 28): pieces of them were
--     received (a posted receipt matched to them - pass 2 matches an unlinked "Shipped in containers" line to the goods
--     of the order's containers as they are received - or returned), or a draft or posted receipt was made from them.
--     Linking would split or move such a line, which usp_PurchaseInvoice_LinkContainers refuses (65028, naming the line
--     and its receipt, ahead of this rule): so the card disables Link / Add / Auto-plan with the reason, and
--     usp_PurchaseInvoice_CheckContainers refuses Add and Auto-plan up front (65030). Document-wide, as the "already
--     received" refusal of LinkContainers is.
-- (63) rule 3 (a draft of several items is split by item first) only for an invoice whose mode is one item.
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
                   OUTER APPLY purchase.fn_PoLine_CommittedOutside(pol.Id, d.Id) dir     -- (65) invoiced by the others, or received, outside containers
                   CROSS APPLY (SELECT Qty = pol.QuantityBase
                                    - ISNULL(dir.Qty, 0)
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
-- (65) rule 28: the first goods receipt that refers to a line of the invoice outside containers (the posted one first;
--      Found = 1 also for pieces received or returned on such a line without a receipt to name; Status 2 posted, 1 draft)
OUTER APPLY (SELECT TOP (1) Found = 1, gr.Status, Number = gr.DocumentNumber
             FROM purchase.PurchaseDocumentLines x
             OUTER APPLY (SELECT TOP (1) r.Status, r.DocumentNumber, r.Id
                          FROM (SELECT g.Id, g.Status, g.DocumentNumber          -- a receipt made from the line, draft or posted
                                FROM purchase.GoodsReceiptLines gl
                                INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId
                                WHERE gl.InvoiceLineId = x.Id AND g.Status < 3
                                UNION ALL
                                SELECT g.Id, g.Status, g.DocumentNumber          -- a posted receipt whose pieces are matched to it
                                FROM purchase.GoodsReceiptInvoiceMatches m
                                INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = m.GoodsReceiptLineId
                                INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId
                                WHERE m.InvoiceLineId = x.Id AND g.Status = 2) r
                          ORDER BY r.Status DESC, r.Id) gr
             WHERE x.DocumentId = d.Id AND x.ContainerLineId IS NULL AND x.SourceLineId IS NOT NULL
               AND (gr.Status IS NOT NULL OR x.ReceivedQuantityBase > 0 OR x.ReturnedQuantityBase > 0)
             ORDER BY CASE WHEN gr.Status = 2 THEN 0 WHEN gr.Status = 1 THEN 1 ELSE 2 END, x.LineNumber) grn
CROSS APPLY (SELECT FailedRule = CAST(CASE
                        WHEN dt.Code <> N'PINV' OR d.Status NOT IN (1, 2) THEN 1
                        WHEN o.Id IS NULL OR ot.Code <> N'PO' OR ln.Typed > 0 THEN 2
                        WHEN ln.ItemCount > 1 AND d.Status = 1 AND oi.OneItemOnly = 1 THEN 3
                        WHEN d.ReceiptMode <> 2 THEN 4
                        WHEN o.Status NOT IN (2, 4) THEN 5
                        WHEN grn.Found = 1 THEN 6
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
                            THEN N'Turn on "Shipped in containers" first: the goods will then enter the stock when their containers are received.'
                        WHEN d.ReceiptMode <> 2 AND d.UsesGoodsReceipts = 1
                            THEN N'This invoice was posted without "Shipped in containers": its goods are received with Receive goods' + NCHAR(8230) + N', not with containers.'
                        WHEN d.ReceiptMode <> 2 THEN N'This invoice was received when it was posted: it cannot be linked to containers.'
                        WHEN o.Status NOT IN (2, 4)
                            THEN N'Order ' + ISNULL(o.DocumentNumber, N'(draft)') + N' is '
                                 + CASE o.Status WHEN 1 THEN N'a draft' WHEN 3 THEN N'cancelled' ELSE N'waiting for approval' END
                                 + N': containers are made from an approved order.'
                        WHEN ln.Lines = 0 THEN N'This invoice has no lines yet.'
                        WHEN grn.Status = 2
                            THEN N'Goods receipt ' + grn.Number + N' already received pieces of this invoice that are not in a container: '
                                 + N'its lines can no longer be linked to containers. The rest is matched to the goods of the order''s '
                                 + N'containers when they are received.'
                        WHEN grn.Status = 1
                            THEN N'A draft goods receipt was made from this invoice: delete it before linking the invoice to containers.'
                        WHEN grn.Found = 1
                            THEN N'Goods of this invoice outside containers were already received or returned: it can no longer be linked to containers.'
                        WHEN ISNULL(u.NotInContainer, 0) = 0 THEN N'Every piece of this invoice is already in a container.'
                        WHEN ISNULL(u.Available, 0) = 0
                            THEN N'Order ' + o.DocumentNumber + N' allows no more pieces: its lines are already loaded in containers'
                                 + N', or invoiced or received outside containers.' END AS NVARCHAR(400))) r
WHERE d.Id = @InvoiceId;
GO

/* ================================================================== 16. Invoice lines a goods receipt refers to stay where they are (rule 28) */

-- Re-created (65) from the body of script 43: no candidate while the invoice fails rule 6 of
-- purchase.fn_PurchaseInvoice_ContainerState - a goods receipt refers to its lines outside containers (rule 28), or
-- every piece is in a container already (then there is nothing to link anyway) - so the "Link containers..." dialog
-- never offers a container that usp_PurchaseInvoice_LinkContainers would refuse.
-- The container lines an invoice can be linked to: containers of its purchase order still Draft or Confirmed, lines of
-- the order lines the invoice still has pieces of outside any container, with something loaded and not yet invoiced
-- (by any invoice that is not cancelled). UnlinkedBase = what the invoice has of that order line outside containers.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseInvoice_LinkCandidates
    @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OrderId INT = (SELECT d.SourceDocumentId FROM purchase.PurchaseDocuments d
                            INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                            WHERE d.Id = @InvoiceId AND dt.Code = N'PINV' AND d.Status IN (1, 2));

    -- (65) rule 6: a goods receipt refers to the invoice's lines outside containers
    IF EXISTS (SELECT 1 FROM purchase.fn_PurchaseInvoice_ContainerState(@InvoiceId) s WHERE s.FailedRule = 6)
        SET @OrderId = NULL;

    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS ContainerStatus,
           cl.Id AS ContainerLineId, cl.LineNumber AS ContainerLineNumber, cl.PoLineId, cl.ItemId, i.ItemCode, i.ItemName,
           LoadedBase    = cl.QuantityBase,
           InvoicedBase  = ISNULL(q.Qty, 0),
           AvailableBase = cl.QuantityBase - ISNULL(q.Qty, 0),
           u.UnlinkedBase
    FROM logistics.ContainerLines cl
    INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
    INNER JOIN inventory.Items i      ON i.Id = cl.ItemId
    INNER JOIN purchase.fn_PurchaseInvoice_Unlinked(@InvoiceId) u ON u.PoLineId = cl.PoLineId
    OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
    WHERE cl.PurchaseOrderId = @OrderId AND c.Status IN (1, 2) AND cl.QuantityBase - ISNULL(q.Qty, 0) > 0
    ORDER BY c.ContainerRef, cl.LineNumber;
END
GO

-- Re-created (65) from the body of script 51: + rule 28 - an invoice line a goods receipt refers to (a draft or posted
-- receipt made from it, or a posted receipt matched to it) is not moved into a container (65028, checked before the
-- invoice's rule 6, which fails for the same lines with 65030); an invoice posted after the switch
-- (UsesGoodsReceipts = 1) without "Shipped in containers" gets the sentence of goods receipts.
-- (51) + the rules of the invoice first (usp_PurchaseInvoice_CheckContainers); a draft is no longer switched to
-- "shipped in containers" here: rule 4 has it turned on first.
-- A draft, or a posted invoice shipped in containers (receipt mode 2), takes container lines of its own order. Its
-- lines of that order line outside containers are SPLIT: the linked part becomes a line of its own (same item, unit,
-- price, discount, warehouse), the rest stays unlinked. A part that is not a whole number of the line's unit is put in
-- the base unit (price per base unit), as usp_PurchaseDocument_CreateFromSource does. The document total is kept: a
-- rounding difference goes on the last line split. A draft still received on posting becomes "shipped in containers".
-- Nothing else needs writing: the order lines count invoiced quantities by the invoice lines, and
-- logistics.ContainerInvoices is the unused table of the old model (script 27).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseInvoice_LinkContainers
    @InvoiceId  INT,
    @RowVersion BINARY(8) = NULL,
    @Links      logistics.tvp_ContainerLineQty READONLY,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @TypeCode NVARCHAR(20), @Status TINYINT, @OrderId INT, @Mode TINYINT, @Number NVARCHAR(30), @UsesGrn BIT;
        SELECT @TypeCode = dt.Code, @Status = d.Status, @OrderId = d.SourceDocumentId, @Mode = d.ReceiptMode,
               @Number = ISNULL(d.DocumentNumber, N'draft #' + CAST(d.Id AS NVARCHAR(10))), @UsesGrn = d.UsesGoodsReceipts
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @InvoiceId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;

        -- (65) RULE 28: AN INVOICE LINE A GOODS RECEIPT REFERS TO STAYS OUTSIDE CONTAINERS (65028, as Unlink answers it).
        -- Linking moves or splits the invoice's lines outside containers: none of them may be the line a draft or posted
        -- receipt was made from (Receive goods... on the invoice), or a line a posted receipt's pieces are matched to, or
        -- carry pieces received or returned. Rule 6 of purchase.fn_PurchaseInvoice_ContainerState fails for the same
        -- lines - the card's reason, and the 65030 of Add container and Auto-plan from the invoice - so this is checked
        -- before usp_PurchaseInvoice_CheckContainers raises it: a Link refused for them names the line and its receipt
        -- (65028). The invoice's rules 1-5 still come first, with their 65030. Document-wide, as rule 6 is: a receipt on
        -- any line outside containers stops the link (a posted one is named first, as the card does).
        DECLARE @Msg NVARCHAR(400), @Rule TINYINT;
        SELECT @Rule = s.FailedRule FROM purchase.fn_PurchaseInvoice_ContainerState(@InvoiceId) s;
        IF @Rule IS NULL OR @Rule >= 6
        BEGIN
            SELECT TOP (1) @Msg = N'Line ' + CAST(pil.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                  + CASE WHEN g.Status = 2 THEN N'goods receipt ' + g.DocumentNumber ELSE N'a draft goods receipt' END
                                  + N' refers to this invoice line: delete or cancel it first.'
            FROM purchase.PurchaseDocumentLines pil
            INNER JOIN inventory.Items i ON i.Id = pil.ItemId
            CROSS APPLY (SELECT TOP (1) r.Status, r.DocumentNumber
                         FROM (SELECT gr.Id, gr.Status, gr.DocumentNumber          -- a receipt made from the line, draft or posted
                               FROM purchase.GoodsReceiptLines gl
                               INNER JOIN purchase.GoodsReceipts gr ON gr.Id = gl.GoodsReceiptId
                               WHERE gl.InvoiceLineId = pil.Id AND gr.Status < 3
                               UNION ALL
                               SELECT gr.Id, gr.Status, gr.DocumentNumber          -- a posted receipt whose pieces are matched to it
                               FROM purchase.GoodsReceiptInvoiceMatches m
                               INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = m.GoodsReceiptLineId
                               INNER JOIN purchase.GoodsReceipts gr     ON gr.Id = gl.GoodsReceiptId
                               WHERE m.InvoiceLineId = pil.Id AND gr.Status = 2) r
                         ORDER BY r.Status DESC, r.Id) g
            WHERE pil.DocumentId = @InvoiceId AND pil.ContainerLineId IS NULL
            ORDER BY CASE WHEN g.Status = 2 THEN 0 ELSE 1 END, pil.LineNumber;
            IF @Msg IS NOT NULL THROW 65028, @Msg, 1;

            IF EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines
                       WHERE DocumentId = @InvoiceId AND ContainerLineId IS NULL AND (ReceivedQuantityBase > 0 OR ReturnedQuantityBase > 0))
                THROW 65028, 'Goods of this invoice outside containers were already received or returned: it can no longer be linked.', 1;
        END

        -- (51) the invoice's rules 1-6: the same sentences as the state of the page
        EXEC purchase.usp_PurchaseInvoice_CheckContainers @InvoiceId = @InvoiceId, @Action = N'Link';
        IF @TypeCode <> N'PINV' OR @OrderId IS NULL
            THROW 65028, 'Only a purchase invoice created from a purchase order can be linked to containers.', 1;
        IF @Status NOT IN (1, 2) THROW 65010, 'A cancelled invoice cannot be linked to containers.', 1;
        IF @Status = 2 AND @Mode <> 2 AND @UsesGrn = 1      -- (65) posted after the switch: its goods come with goods receipts
        BEGIN
            SET @Msg = N'This invoice was posted without "Shipped in containers": its goods are received with Receive goods' + NCHAR(8230) + N', not with containers.';
            THROW 65028, @Msg, 1;
        END
        IF @Status = 2 AND @Mode <> 2
            THROW 65028, 'This invoice was received when it was posted: it cannot be linked to containers.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM @Links) THROW 65000, 'Choose at least one container line to link.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @InvoiceId)
            THROW 65020, 'This invoice has its own charges. Remove them: the charges of an import are entered on its containers.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE SourceInvoiceId = @InvoiceId AND Status <> 3)
            THROW 65028, 'This invoice has a landed cost adjustment: cancel or delete it before linking the invoice to containers.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments r WHERE r.SourceDocumentId = @InvoiceId AND r.Status <> 3)
            THROW 65028, 'This invoice has purchase returns: it can no longer be linked to containers.', 1;

        -- the containers: still Draft or Confirmed
        SELECT TOP (1) @Msg = CASE WHEN c.Status = 8 THEN N'Container ' + c.ContainerRef + N' is cancelled.'
                                   ELSE N'Container ' + c.ContainerRef + N' has started moving: it can no longer be linked.' END
        FROM @Links k
        INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
        INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        WHERE c.Status NOT IN (1, 2)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 65027, @Msg, 1;

        -- the lines: of this order, a quantity, within what is loaded and not yet invoiced
        SELECT TOP (1) @Msg =
            CASE WHEN cl.Id IS NULL THEN N'A container line to link no longer exists.'
                 WHEN cl.PurchaseOrderId <> @OrderId THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10))
                      + N' belongs to another purchase order.'
                 WHEN k.QuantityBase <= 0 THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10))
                      + N': the quantity must be greater than zero.'
                 ELSE N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                      + CAST(k.QuantityBase AS NVARCHAR(20)) + N' to link but only ' + CAST(cl.QuantityBase - ISNULL(q.Qty, 0) AS NVARCHAR(20))
                      + N' are loaded and not yet invoiced.' END
        FROM @Links k
        LEFT JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
        LEFT JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        LEFT JOIN inventory.Items i           ON i.Id = cl.ItemId
        OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
        WHERE cl.Id IS NULL OR cl.PurchaseOrderId <> @OrderId OR k.QuantityBase <= 0
           OR k.QuantityBase > cl.QuantityBase - ISNULL(q.Qty, 0)
        ORDER BY c.ContainerRef, cl.LineNumber;
        IF @Msg IS NOT NULL THROW 65019, @Msg, 1;

        -- the invoice: within its pieces of that order line outside containers
        SELECT TOP (1) @Msg = i.ItemCode + N': ' + CAST(t.Qty AS NVARCHAR(20)) + N' pieces to link but only '
                              + CAST(ISNULL(u.UnlinkedBase, 0) AS NVARCHAR(20)) + N' of this invoice (order line '
                              + CAST(pol.LineNumber AS NVARCHAR(10)) + N') are not in a container yet.'
        FROM (SELECT cl.PoLineId, Qty = SUM(k.QuantityBase) FROM @Links k
              INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId GROUP BY cl.PoLineId) t
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = t.PoLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        LEFT  JOIN purchase.fn_PurchaseInvoice_Unlinked(@InvoiceId) u ON u.PoLineId = t.PoLineId
        WHERE t.Qty > ISNULL(u.UnlinkedBase, 0)
        ORDER BY pol.LineNumber;
        IF @Msg IS NOT NULL THROW 65019, @Msg, 1;

        DECLARE @OldTotal DECIMAL(18,2) = (SELECT ISNULL(SUM(LineTotal), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        DECLARE @NextNo INT = (SELECT ISNULL(MAX(LineNumber), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        DECLARE @Cl INT, @PoLineId INT, @Need INT, @LineId INT, @Have INT, @Pf INT, @ItemId INT, @BaseUnit INT, @LastLine INT;

        DECLARE links CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT k.ContainerLineId, cl.PoLineId, k.QuantityBase
            FROM @Links k
            INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
            INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
            ORDER BY c.ContainerRef, cl.LineNumber;
        OPEN links;
        FETCH NEXT FROM links INTO @Cl, @PoLineId, @Need;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            WHILE @Need > 0
            BEGIN
                SET @LineId = NULL;
                SELECT TOP (1) @LineId = Id, @Have = QuantityBase, @Pf = PackingFormula, @ItemId = ItemId
                FROM purchase.PurchaseDocumentLines
                WHERE DocumentId = @InvoiceId AND ContainerLineId IS NULL AND SourceLineId = @PoLineId AND QuantityBase > 0
                ORDER BY LineNumber;
                IF @LineId IS NULL THROW 65019, 'The invoice has no more pieces of that order line outside containers.', 1;

                IF @Have <= @Need
                BEGIN
                    -- the whole line goes into the container
                    UPDATE purchase.PurchaseDocumentLines SET ContainerLineId = @Cl WHERE Id = @LineId;
                    SET @Need -= @Have;
                    SET @LastLine = @LineId;
                END
                ELSE
                BEGIN
                    SET @BaseUnit = (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = @ItemId AND IsBaseUnit = 1 ORDER BY Id);
                    IF @BaseUnit IS NULL AND (@Need % @Pf <> 0 OR (@Have - @Need) % @Pf <> 0)
                        THROW 65028, 'The item of a line to split has no base unit.', 1;

                    -- the linked part: a new line
                    SET @NextNo += 1;
                    INSERT INTO purchase.PurchaseDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                                                UnitPrice, DiscountPercent, UnitCostBase, ReceivedQuantityBase, ReturnedQuantityBase,
                                                                ImportRowNumber, Notes, SourceLineId, ShippedQuantityBase, FobCostBase, AllocatedChargesBase,
                                                                ContainerLineId)
                    SELECT @InvoiceId, @NextNo, l.ItemId,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN l.ItemUnitId ELSE @BaseUnit END,
                           l.WarehouseId, l.ExpiryDate,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN @Need / l.PackingFormula ELSE @Need END,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN l.PackingFormula ELSE 1 END,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN l.UnitPrice ELSE ROUND(l.UnitPrice / l.PackingFormula, 4) END,
                           l.DiscountPercent, l.UnitCostBase, 0, 0, l.ImportRowNumber, l.Notes, l.SourceLineId, 0, l.FobCostBase, 0, @Cl
                    FROM purchase.PurchaseDocumentLines l
                    WHERE l.Id = @LineId;

                    -- the rest stays where it was, unlinked (it keeps its id: what refers to the line still finds it)
                    UPDATE purchase.PurchaseDocumentLines
                    SET ItemUnitId     = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN ItemUnitId ELSE @BaseUnit END,
                        Quantity       = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN (@Have - @Need) / PackingFormula ELSE @Have - @Need END,
                        UnitPrice      = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN UnitPrice ELSE ROUND(UnitPrice / PackingFormula, 4) END,
                        PackingFormula = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN PackingFormula ELSE 1 END
                    WHERE Id = @LineId;

                    SET @Need = 0;
                    SET @LastLine = @LineId;
                END
            END
            FETCH NEXT FROM links INTO @Cl, @PoLineId, @Need;
        END
        CLOSE links;
        DEALLOCATE links;

        -- the lines of every container first, by container, then what is not in a container yet
        UPDATE l SET LineNumber = x.Seq
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN (SELECT pl.Id, Seq = ROW_NUMBER() OVER (ORDER BY CASE WHEN pl.ContainerLineId IS NULL THEN 1 ELSE 0 END,
                                                                    c.ContainerRef, cl.LineNumber, pl.LineNumber, pl.Id)
                    FROM purchase.PurchaseDocumentLines pl
                    LEFT JOIN logistics.ContainerLines cl ON cl.Id = pl.ContainerLineId
                    LEFT JOIN logistics.Containers c      ON c.Id = cl.ContainerId
                    WHERE pl.DocumentId = @InvoiceId) x ON x.Id = l.Id
        WHERE l.LineNumber <> x.Seq;

        -- the document total does not change: a rounding difference goes on the last line split
        DECLARE @Diff DECIMAL(18,2) = @OldTotal - (SELECT ISNULL(SUM(LineTotal), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        IF @Diff <> 0 AND @LastLine IS NOT NULL
            UPDATE purchase.PurchaseDocumentLines
            SET UnitPrice = ROUND(UnitPrice + @Diff / NULLIF(Quantity * (1 - DiscountPercent / 100.0), 0), 4)
            WHERE Id = @LastLine;

        UPDATE d
        SET ReceiptMode = 2,
            TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / d.ExchangeRate, 2), TotalLandedCostBase = ROUND(x.Amt / d.ExchangeRate, 2) + d.TotalChargesBase,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId) x
        WHERE d.Id = @InvoiceId;

        -- the value basis of the container charges follows the invoice, and both sides keep the history
        DECLARE @Cid INT, @Ref NVARCHAR(30), @Qty INT;
        DECLARE cts CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT cl.ContainerId, c.ContainerRef, SUM(k.QuantityBase)
            FROM @Links k
            INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
            INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
            GROUP BY cl.ContainerId, c.ContainerRef
            ORDER BY c.ContainerRef;
        OPEN cts;
        FETCH NEXT FROM cts INTO @Cid, @Ref, @Qty;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Cid, N'Updated', N'Linked to purchase invoice ' + @Number + N': ' + CAST(@Qty AS NVARCHAR(20)) + N' pieces', @UserId);
            FETCH NEXT FROM cts INTO @Cid, @Ref, @Qty;
        END
        CLOSE cts;
        DEALLOCATE cts;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT @InvoiceId, N'Updated',
               LEFT(N'Linked to containers ' + STRING_AGG(x.Ref + N' (' + CAST(x.Qty AS NVARCHAR(20)) + N')', N', ')
                    WITHIN GROUP (ORDER BY x.Ref), 1000), @UserId
        FROM (SELECT Ref = c.ContainerRef, Qty = SUM(k.QuantityBase)
              FROM @Links k
              INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
              INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
              GROUP BY c.ContainerRef) x;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseInvoice_ContainerSummary @InvoiceId;
END
GO

-- Re-created (65) from the body of script 43: + rule 28 - an invoice line a goods receipt refers to (a draft or posted
-- receipt made from it, or a posted receipt matched to it: order-line matching reaches lines in containers not received
-- yet) is not unlinked (65028); and a freed line a cancelled receipt still refers to keeps its id (it is not merged
-- away: the receipt line's foreign key points to it).
-- The container must still be Draft or Confirmed (nothing received). The invoice lines on it lose their container and
-- go back into the unlinked line of the same order line, item, unit, price, discount, warehouse and expiry when there
-- is one (otherwise they stay as separate unlinked lines). The invoice stays "shipped in containers".
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseInvoice_UnlinkContainer
    @InvoiceId   INT,
    @ContainerId INT,
    @RowVersion  BINARY(8) = NULL,
    @UserId      INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @TypeCode NVARCHAR(20), @Status TINYINT, @Number NVARCHAR(30);
        SELECT @TypeCode = dt.Code, @Status = d.Status, @Number = ISNULL(d.DocumentNumber, N'draft #' + CAST(d.Id AS NVARCHAR(10)))
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @InvoiceId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PINV' THROW 65028, 'Only a purchase invoice can be unlinked from a container.', 1;
        IF @Status NOT IN (1, 2) THROW 65010, 'A cancelled invoice cannot be changed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

        DECLARE @Ref NVARCHAR(30), @CStatus TINYINT, @Msg NVARCHAR(400);
        SELECT @Ref = ContainerRef, @CStatus = Status FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @ContainerId;
        IF @Ref IS NULL OR NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                                       INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                                       WHERE l.DocumentId = @InvoiceId AND cl.ContainerId = @ContainerId)
        BEGIN
            SET @Msg = N'Container ' + ISNULL(@Ref, N'#' + CAST(@ContainerId AS NVARCHAR(10))) + N' is not linked to this invoice.';
            THROW 65019, @Msg, 1;
        END
        IF @CStatus NOT IN (1, 2) OR EXISTS (SELECT 1 FROM logistics.ContainerLines WHERE ContainerId = @ContainerId AND ISNULL(ReceivedQuantityBase, 0) > 0)
        BEGIN
            SET @Msg = N'Container ' + @Ref + N' has started moving: it can no longer be unlinked.';
            THROW 65027, @Msg, 1;
        END

        -- (65) RULE 28: AN INVOICE LINE A GOODS RECEIPT REFERS TO STAYS IN ITS CONTAINER: the line a draft or posted
        -- receipt was made from, or a line a posted receipt's pieces are matched to (an order line's receipts outside
        -- containers are matched to its invoice lines, linked or not).
        SET @Msg = NULL;
        SELECT TOP (1) @Msg = N'Line ' + CAST(pil.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                              + CASE WHEN g.Status = 2 THEN N'goods receipt ' + g.DocumentNumber ELSE N'a draft goods receipt' END
                              + N' refers to this invoice line: delete or cancel it first.'
        FROM purchase.PurchaseDocumentLines pil
        INNER JOIN logistics.ContainerLines cl ON cl.Id = pil.ContainerLineId
        INNER JOIN inventory.Items i           ON i.Id = pil.ItemId
        CROSS APPLY (SELECT TOP (1) r.Status, r.DocumentNumber
                     FROM (SELECT gr.Id, gr.Status, gr.DocumentNumber          -- a receipt made from the line, draft or posted
                           FROM purchase.GoodsReceiptLines gl
                           INNER JOIN purchase.GoodsReceipts gr ON gr.Id = gl.GoodsReceiptId
                           WHERE gl.InvoiceLineId = pil.Id AND gr.Status < 3
                           UNION ALL
                           SELECT gr.Id, gr.Status, gr.DocumentNumber          -- a posted receipt whose pieces are matched to it
                           FROM purchase.GoodsReceiptInvoiceMatches m
                           INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = m.GoodsReceiptLineId
                           INNER JOIN purchase.GoodsReceipts gr     ON gr.Id = gl.GoodsReceiptId
                           WHERE m.InvoiceLineId = pil.Id AND gr.Status = 2) r
                     ORDER BY r.Status DESC, r.Id) g
        WHERE pil.DocumentId = @InvoiceId AND cl.ContainerId = @ContainerId
        ORDER BY pil.LineNumber;
        IF @Msg IS NOT NULL THROW 65028, @Msg, 1;

        DECLARE @OldTotal DECIMAL(18,2) = (SELECT ISNULL(SUM(LineTotal), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        DECLARE @Pieces INT;

        DECLARE @Freed TABLE (Id INT PRIMARY KEY);
        UPDATE l SET ContainerLineId = NULL
        OUTPUT inserted.Id INTO @Freed (Id)
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
        WHERE l.DocumentId = @InvoiceId AND cl.ContainerId = @ContainerId;
        SET @Pieces = (SELECT SUM(l.QuantityBase) FROM purchase.PurchaseDocumentLines l INNER JOIN @Freed f ON f.Id = l.Id);

        -- back into the unlinked line of the same kind: the one that was there before, else the first freed one
        DECLARE @Merge TABLE (Id INT PRIMARY KEY, KeeperId INT NOT NULL);
        INSERT INTO @Merge (Id, KeeperId)
        SELECT g.Id, g.KeeperId
        FROM (SELECT l.Id,
                     IsFreed  = CASE WHEN f.Id IS NOT NULL THEN 1 ELSE 0 END,
                     KeeperId = FIRST_VALUE(l.Id) OVER (PARTITION BY l.SourceLineId, l.ItemId, l.ItemUnitId, l.UnitPrice, l.DiscountPercent,
                                                                     l.WarehouseId, l.ExpiryDate
                                                        ORDER BY CASE WHEN f.Id IS NULL THEN 0 ELSE 1 END, l.Id)
              FROM purchase.PurchaseDocumentLines l
              LEFT JOIN @Freed f ON f.Id = l.Id
              WHERE l.DocumentId = @InvoiceId AND l.ContainerLineId IS NULL) g
        WHERE g.IsFreed = 1 AND g.Id <> g.KeeperId
          AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines gl WHERE gl.InvoiceLineId = g.Id);   -- (65) kept: a receipt line refers to it

        UPDATE k SET Quantity = k.Quantity + x.Qty
        FROM purchase.PurchaseDocumentLines k
        INNER JOIN (SELECT m.KeeperId, Qty = SUM(l.Quantity) FROM @Merge m
                    INNER JOIN purchase.PurchaseDocumentLines l ON l.Id = m.Id GROUP BY m.KeeperId) x ON x.KeeperId = k.Id;
        DELETE l FROM purchase.PurchaseDocumentLines l INNER JOIN @Merge m ON m.Id = l.Id;

        UPDATE l SET LineNumber = x.Seq
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN (SELECT pl.Id, Seq = ROW_NUMBER() OVER (ORDER BY CASE WHEN pl.ContainerLineId IS NULL THEN 1 ELSE 0 END,
                                                                    c.ContainerRef, cl.LineNumber, pl.LineNumber, pl.Id)
                    FROM purchase.PurchaseDocumentLines pl
                    LEFT JOIN logistics.ContainerLines cl ON cl.Id = pl.ContainerLineId
                    LEFT JOIN logistics.Containers c      ON c.Id = cl.ContainerId
                    WHERE pl.DocumentId = @InvoiceId) x ON x.Id = l.Id
        WHERE l.LineNumber <> x.Seq;

        -- the document total does not change: a rounding difference goes on the line the pieces went back to
        DECLARE @LastLine INT = (SELECT TOP (1) KeeperId FROM @Merge ORDER BY KeeperId DESC);
        DECLARE @Diff DECIMAL(18,2) = @OldTotal - (SELECT ISNULL(SUM(LineTotal), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        IF @Diff <> 0 AND @LastLine IS NOT NULL
            UPDATE purchase.PurchaseDocumentLines
            SET UnitPrice = ROUND(UnitPrice + @Diff / NULLIF(Quantity * (1 - DiscountPercent / 100.0), 0), 4)
            WHERE Id = @LastLine;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / d.ExchangeRate, 2), TotalLandedCostBase = ROUND(x.Amt / d.ExchangeRate, 2) + d.TotalChargesBase,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId) x
        WHERE d.Id = @InvoiceId;

        EXEC logistics.usp_Container_ReallocateCharges @ContainerId, 1, 1;
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@ContainerId, N'Updated', N'Unlinked from purchase invoice ' + @Number + N': ' + CAST(ISNULL(@Pieces, 0) AS NVARCHAR(20)) + N' pieces', @UserId);
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@InvoiceId, N'Updated', N'Unlinked from container ' + @Ref + N' (' + CAST(ISNULL(@Pieces, 0) AS NVARCHAR(20)) + N')', @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseInvoice_ContainerSummary @InvoiceId;
END
GO

/* ================================================================== 17. The container page and list: receipts, Delivery, Receive goods... */

-- Re-created (65) from the body of script 54: goods receipts. The header + who received the container (ReceivedBy:
-- 'GRN' a posted goods receipt, 'Offload' the offload of before, NULL not received - the only test, so Cancel Offload is
-- offered for 'Offload' only), its open goods receipt (a draft or the posted one: GoodsReceipt*), its latest completed
-- Delivery (DeliveredDate, DeliveryMovement*, DeliveryPlaceName) and CanReceive ("Receive goods...": Confirmed to
-- Cleared, no open receipt); the days at the port stop at the Delivery when nothing is received yet (edge case 29).
-- CloseBlockedReason: why an offloaded container cannot be closed yet (fn_Container_CloseBlock, the refusal of Close).
-- The lines' FobSource 'Offload' becomes 'Received': the container line's value once the goods are received. Columns
-- added at the end of set 1; the other sets are unchanged.
-- (54) from the body of script 27: the fill from the items' Container units (FillPct, CapacityKnown,
-- MissingContainerUnitItems, RemainingPcs, IsOverCapacity) instead of MaxUnits / TypeMaxUnits / UtilizationPct /
-- RemainingCapacityBase; the lines give each item's PcsPerContainer.
CREATE OR ALTER PROCEDURE logistics.usp_Container_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT c.Id, c.DocumentTypeId, c.ContainerRef, c.ContainerNo,
           c.ContainerTypeId, ct.TypeCode AS ContainerTypeCode, ct.TypeName AS ContainerTypeName,
           ct.MaxWeightKg, ct.MaxVolumeCbm,
           c.SealNo, c.CustomsSealNo, c.Description,
           c.OrderDate, c.OrderMonthKey, OrderMonth = FORMAT(c.OrderDate, N'MMM-yyyy', N'en-US'),
           c.ShippingMethod, c.CountryOfOrigin,
           c.PurchaseOrderId, mpo.DocumentNumber AS PurchaseOrderNumber, mpo.SupplierId AS PurchaseOrderSupplierId,
           mps.PartyName AS PurchaseOrderSupplierName,
           c.ForwarderId, fw.PartyName AS ForwarderName, c.TransporterId, tr.PartyName AS TransporterName,
           c.ShippingLine, c.VesselName, c.VoyageNo, c.BookingNo,
           c.PortOfLoadingId, pl.PortName AS PortOfLoadingName, pl.CountryCode AS PortOfLoadingCountry,
           c.PortOfDestinationId, pd.PortName AS PortOfDestinationName, pd.CountryCode AS PortOfDestinationCountry,
           c.FinalDestinationId, fd.PortName AS FinalDestinationName,
           c.DispatchDate, c.Eta, c.FreeDays, c.LastFreeDay, c.GrossWeightKg, c.VolumeCbm, c.Packages,
           c.BlNo, c.BlDate, c.BlNotes,
           c.TotalLines, c.TotalAllocatedBase, c.TotalReceivedBase, c.TotalOilQty,
           fl.FillPct, fl.CapacityKnown, fl.MissingContainerUnitItems, fl.RemainingPcs, fl.IsOverCapacity,
           c.BranchId, b.BranchCode, b.BranchName, c.WarehouseId, w.WarehouseCode, w.WarehouseName,
           c.TruckNo, c.WaybillNo, c.DeclarationNo, c.FeriNo,
           c.ActualPortArrival, c.BorderCrossingDate, c.CustomsReleaseDate,
           DaysAtPort = CASE WHEN c.ActualPortArrival IS NOT NULL      -- (65) up to the receipt, else the Delivery, else today
                             THEN DATEDIFF(DAY, c.ActualPortArrival, COALESCE(c.OffloadedDate, dl.EndDate, CAST(SYSUTCDATETIME() AS DATE))) END,
           c.OffloadedDate, c.OffloadedAtUtc, c.OffloadedBy, ou.FullName AS OffloadedByName,
           c.Status, c.StatusNote, c.CurrentLocation, c.Notes,
           c.DatesFromMovements,
           HasMovements = CAST(CASE WHEN EXISTS (SELECT 1 FROM logistics.MovementContainers mc
                                                 INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                                                 WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)) THEN 1 ELSE 0 END AS BIT),
           InvoicedPostedBase = ISNULL(inv.Posted, 0), InvoicedDraftBase = ISNULL(inv.Draft, 0),
           IsFullyInvoiced = CAST(CASE WHEN c.TotalAllocatedBase > 0 AND NOT EXISTS
                                       (SELECT 1 FROM logistics.ContainerLines cl
                                        OUTER APPLY (SELECT Q = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                                                     INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                                                     WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (2, 4)) q
                                        WHERE cl.ContainerId = c.Id AND ISNULL(q.Q, 0) < cl.QuantityBase) THEN 1 ELSE 0 END AS BIT),
           ChargesPostedBase = ISNULL(chg.Posted, 0), ChargesDraftBase = ISNULL(chg.Draft, 0),
           ChargesLandedPostedBase = ISNULL(chg.LandedPosted, 0),
           FobTotalBase = cost.Fob, LandedTotalBase = cost.Fob + ISNULL(chg.LandedPosted, 0),
           c.ConfirmedAtUtc, c.ConfirmedBy, fu.FullName AS ConfirmedByName,
           c.ClosedAtUtc, c.ClosedBy, ku.FullName AS ClosedByName,
           c.CancelledAtUtc, c.CancelledBy, xu.FullName AS CancelledByName, c.CancelReason,
           c.CreatedAtUtc, c.CreatedBy, cu.FullName AS CreatedByName,
           c.UpdatedAtUtc, c.UpdatedBy, uu.FullName AS UpdatedByName, c.RowVersion,
           -- (65) goods receipts
           rb.ReceivedBy,
           rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus,
           GoodsReceiptDate = gr.DocumentDate, GoodsReceiptIsAuto = gr.IsAuto,
           GoodsReceiptWarehouseId = gr.WarehouseId, GoodsReceiptWarehouseCode = gw.WarehouseCode,
           GoodsReceiptCreatedAtUtc = gr.CreatedAtUtc,
           DeliveredDate = dl.EndDate, DeliveryMovementId = dl.MovementId, DeliveryMovementNo = dl.MovementNo,
           DeliveryPlaceName = dl.PlaceName,
           CanReceive = CAST(CASE WHEN c.Status BETWEEN 2 AND 5 AND rb.GoodsReceiptId IS NULL THEN 1 ELSE 0 END AS BIT),
           CloseBlockedReason = cb.Reason
    FROM logistics.Containers c
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    CROSS APPLY logistics.fn_ContainerFill(c.Id) fl
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb      -- (65) who received it; its open goods receipt
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl    -- (65) its latest completed Delivery
    OUTER APPLY (SELECT b.Reason FROM logistics.fn_Container_CloseBlock(c.Id) b WHERE c.Status = 6) cb  -- (65) why not Close
    LEFT  JOIN purchase.GoodsReceipts gr    ON gr.Id = rb.GoodsReceiptId
    LEFT  JOIN masterdata.Warehouses gw     ON gw.Id = gr.WarehouseId
    LEFT  JOIN purchase.PurchaseDocuments mpo ON mpo.Id = c.PurchaseOrderId
    LEFT  JOIN masterdata.Parties mps       ON mps.Id = mpo.SupplierId
    LEFT  JOIN masterdata.Parties fw        ON fw.Id = c.ForwarderId
    LEFT  JOIN masterdata.Parties tr        ON tr.Id = c.TransporterId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN masterdata.Ports fd          ON fd.Id = c.FinalDestinationId
    LEFT  JOIN security.Users ou ON ou.Id = c.OffloadedBy
    LEFT  JOIN security.Users fu ON fu.Id = c.ConfirmedBy
    LEFT  JOIN security.Users ku ON ku.Id = c.ClosedBy
    LEFT  JOIN security.Users xu ON xu.Id = c.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = c.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = c.UpdatedBy
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase END),
                        Draft  = SUM(CASE WHEN d.Status = 1 THEN pil.QuantityBase END)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                 INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                 WHERE cl.ContainerId = c.Id) inv
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN ch.Status = 2 THEN ch.AmountBase END),
                        Draft  = SUM(CASE WHEN ch.Status = 1 THEN ch.AmountBase END),
                        LandedPosted = SUM(CASE WHEN ch.Status = 2 AND ch.IncludeInLandedCost = 1 THEN ch.AmountBase END)
                 FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id) chg
    OUTER APPLY (SELECT Fob = SUM(CAST(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase) AS DECIMAL(18,6)) * ISNULL(u.UnitFob, 0))
                 FROM logistics.ContainerLines cl
                 OUTER APPLY (SELECT UnitFob = COALESCE(cl.FobCostBase,
                                                        (SELECT SUM(pil.LineTotal / pid.ExchangeRate) / NULLIF(SUM(pil.QuantityBase), 0)
                                                         FROM purchase.PurchaseDocumentLines pil
                                                         INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                                                         WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (1, 2, 4)),
                                                        (SELECT pol.LineTotal / pod.ExchangeRate / NULLIF(pol.QuantityBase, 0)
                                                         FROM purchase.PurchaseDocumentLines pol
                                                         INNER JOIN purchase.PurchaseDocuments pod ON pod.Id = pol.DocumentId
                                                         WHERE pol.Id = cl.PoLineId))) u
                 WHERE cl.ContainerId = c.Id) cost
    WHERE c.Id = @Id;

    -- 2: lines. FOB per unit: once the goods are received the container line's value (frozen by an offload of before; set by
    -- the goods receipt and moved by the invoices since), else the invoices (posted or draft), else the order price.
    SELECT cl.Id, cl.ContainerId, cl.LineNumber,
           cl.PurchaseOrderId, po.DocumentNumber AS PurchaseOrderNumber, po.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           cl.PoLineId, pol.LineNumber AS PoLineNumber,
           cl.ItemId, i.ItemCode, i.ItemName, i.Model, br.BrandName,
           cl.ItemUnitId, ut.UnitTypeName, cl.PackingFormula,
           PoUnitTypeName = pt.UnitTypeName, PoPackingFormula = pol.PackingFormula,
           PcsPerContainer = ipc.PcsPerContainer,
           cl.Quantity, cl.QuantityBase, cl.OilIncluded, cl.OilQtyPerUnit, cl.TotalOilQty,
           OrderedBase = pol.QuantityBase,
           LoadedElsewhereBase = ISNULL(oth.Qty, 0),
           InvoicedPostedBase = ISNULL(inv.Posted, 0), InvoicedDraftBase = ISNULL(inv.Draft, 0),
           AvailableToInvoiceBase = cl.QuantityBase - ISNULL(inv.Posted, 0) - ISNULL(inv.Draft, 0),
           InvoiceNumbers = inv.Numbers,
           cl.ReceivedQuantityBase, cl.VarianceReason, cl.Notes,
           UnitFobBase = COALESCE(cl.FobCostBase, inv.UnitValue, pol.LineTotal / po.ExchangeRate / NULLIF(pol.QuantityBase, 0)),
           FobSource = CASE WHEN cl.FobCostBase IS NOT NULL THEN N'Received' WHEN inv.UnitValue IS NOT NULL THEN N'Invoice' ELSE N'Order' END,
           cl.FobCostBase, cl.ChargesBase,
           DraftChargesBase = ISNULL(dch.Draft, 0),
           ChargesPerUnitBase = cl.ChargesBase / NULLIF(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase), 0),
           LandedCostBase = COALESCE(cl.LandedCostBase,
                                     COALESCE(inv.UnitValue, pol.LineTotal / po.ExchangeRate / NULLIF(pol.QuantityBase, 0))
                                     + cl.ChargesBase / NULLIF(cl.QuantityBase, 0)),
           IsLandedFinal = CAST(CASE WHEN cl.LandedCostBase IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           i.WeightKg, i.VolumeCbm
    FROM logistics.ContainerLines cl
    INNER JOIN purchase.PurchaseDocuments po     ON po.Id = cl.PurchaseOrderId
    INNER JOIN masterdata.Parties sp             ON sp.Id = po.SupplierId
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
    INNER JOIN inventory.ItemUnits piu           ON piu.Id = pol.ItemUnitId
    INNER JOIN masterdata.UnitTypes pt           ON pt.Id = piu.UnitTypeId
    INNER JOIN inventory.Items i                 ON i.Id = cl.ItemId
    INNER JOIN masterdata.Brands br              ON br.Id = i.BrandId
    INNER JOIN inventory.ItemUnits iu            ON iu.Id = cl.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut           ON ut.Id = iu.UnitTypeId
    CROSS APPLY logistics.fn_ItemPcsPerContainer(cl.ItemId) ipc
    OUTER APPLY (SELECT Qty = SUM(o.QuantityBase) FROM logistics.ContainerLines o
                 INNER JOIN logistics.Containers oc ON oc.Id = o.ContainerId
                 WHERE o.PoLineId = cl.PoLineId AND o.ContainerId <> cl.ContainerId AND oc.Status <> 8) oth
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase END),
                        Draft  = SUM(CASE WHEN d.Status = 1 THEN pil.QuantityBase END),
                        UnitValue = SUM(pil.LineTotal / d.ExchangeRate) / NULLIF(SUM(pil.QuantityBase), 0),
                        Numbers = STRING_AGG(d.DocumentNumber, N', ')
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND d.Status <> 3) inv
    OUTER APPLY (SELECT Draft = SUM(a.AmountBase) FROM logistics.ContainerChargeAllocations a
                 INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId
                 WHERE a.ContainerLineId = cl.Id AND ch.Status = 1) dch
    WHERE cl.ContainerId = @Id
    ORDER BY cl.LineNumber;

    -- 3: invoices of the container (derived from the invoice lines)
    SELECT d.Id AS PurchaseDocumentId, d.DocumentNumber, d.DocumentDate, d.Status AS InvoiceStatus, d.ReceiptMode,
           d.SourceDocumentId AS PurchaseOrderId, po.DocumentNumber AS PurchaseOrderNumber,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, cur.CurrencyCode, cur.Symbol AS CurrencySymbol, d.ExchangeRate,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo,
           QtyInContainerBase = SUM(pil.QuantityBase),
           AmountInContainer = SUM(pil.LineTotal),
           AmountInContainerBase = SUM(pil.LineTotal / d.ExchangeRate),
           d.TotalAmount, d.TotalAmountBase
    FROM logistics.ContainerLines cl
    INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
    INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
    INNER JOIN masterdata.Parties sp               ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies cur           ON cur.Id = d.CurrencyId
    LEFT  JOIN purchase.PurchaseDocuments po       ON po.Id = d.SourceDocumentId
    WHERE cl.ContainerId = @Id AND d.Status <> 3
    GROUP BY d.Id, d.DocumentNumber, d.DocumentDate, d.Status, d.ReceiptMode, d.SourceDocumentId, po.DocumentNumber,
             d.SupplierId, sp.PartyCode, sp.PartyName, d.CurrencyId, cur.CurrencyCode, cur.Symbol, d.ExchangeRate,
             d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo, d.TotalAmount, d.TotalAmountBase
    ORDER BY d.DocumentDate, d.Id;

    -- 4: movements of the container (the route), oldest first
    SELECT m.Id AS MovementId, m.MovementNo, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.CountryCode AS FromCountry, fp.Kind AS FromKind,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.CountryCode AS ToCountry, tp.Kind AS ToKind,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status,
           m.CarrierPartyId, cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo, m.Reference, m.Notes,
           ContainerCount = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = m.Id),
           ChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch
                          WHERE ch.ContainerId = @Id AND ch.MovementId = m.Id AND ch.Status = 2),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ContainerId = @Id AND a.MovementId = m.Id)
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Movements m       ON m.Id = mc.MovementId
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId
    WHERE mc.ContainerId = @Id
    ORDER BY CASE m.Status WHEN 4 THEN 1 ELSE 0 END, COALESCE(m.StartDate, m.PlannedDate, CAST(m.CreatedAtUtc AS DATE)), m.Id;

    -- 5: charges of the container
    SELECT ch.Id, ch.ContainerId, ch.MovementId, m.MovementNo, ch.GroupId,
           GroupSize = CASE WHEN ch.GroupId IS NULL THEN 1 ELSE (SELECT COUNT(*) FROM logistics.ContainerCharges g WHERE g.GroupId = ch.GroupId) END,
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName AS ProviderName, ch.Reference,
           ch.ChargeDate, ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.AppliedAtOffload, ch.AdjustedAfterOffload,
           AllocatedBase = (SELECT SUM(a.AmountBase) FROM logistics.ContainerChargeAllocations a WHERE a.ChargeId = ch.Id),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ChargeId = ch.Id),
           ch.Notes, ch.PostedAtUtc, pu.FullName AS PostedByName, ch.CancelledAtUtc, ch.CancelReason,
           ch.CreatedAtUtc, cu.FullName AS CreatedByName, ch.RowVersion
    FROM logistics.ContainerCharges ch
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    LEFT  JOIN logistics.Movements m     ON m.Id = ch.MovementId
    LEFT  JOIN security.Users pu         ON pu.Id = ch.PostedBy
    LEFT  JOIN security.Users cu         ON cu.Id = ch.CreatedBy
    WHERE ch.ContainerId = @Id
    ORDER BY ch.ChargeDate, ch.Id;

    -- 6: how every charge is divided over the lines (the real cost of each item)
    SELECT a.ChargeId, a.ContainerLineId, cl.LineNumber, cl.ItemId, i.ItemCode, i.ItemName,
           a.Basis, a.AmountBase, a.IsManual,
           PerUnitBase = a.AmountBase / NULLIF(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase), 0)
    FROM logistics.ContainerChargeAllocations a
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId
    INNER JOIN logistics.ContainerLines cl   ON cl.Id = a.ContainerLineId
    INNER JOIN inventory.Items i             ON i.Id = cl.ItemId
    WHERE ch.ContainerId = @Id
    ORDER BY a.ChargeId, cl.LineNumber;

    -- 7: attachments (general, per movement, per charge); SharedWith = other containers holding the same file
    SELECT a.Id, a.ContainerId, a.MovementId, m.MovementNo, a.ChargeId, a.AttachmentTypeId, at.Category, at.SubType,
           a.FileId, f.FileName, f.ContentType, f.SizeBytes, a.Note, a.DocumentDate, a.GroupId,
           SharedWith = (SELECT COUNT(*) FROM logistics.ContainerAttachments s WHERE s.FileId = a.FileId AND s.Id <> a.Id),
           a.CreatedAtUtc, a.CreatedBy, u.FullName AS CreatedByName
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Files f ON f.Id = a.FileId
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    LEFT  JOIN logistics.Movements m         ON m.Id = a.MovementId
    LEFT  JOIN security.Users u              ON u.Id = a.CreatedBy
    WHERE a.ContainerId = @Id
    ORDER BY a.CreatedAtUtc DESC, a.Id DESC;

    -- 8: audit
    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM logistics.ContainerAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.ContainerId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

-- Re-created (65) from the body of script 54: goods receipts. + the filter @DeliveredNotReceived ("Delivered, not
-- received": Confirmed to Cleared, no posted goods receipt, and a completed Delivery-stage movement or a draft
-- receipt); + ReceivedBy, the open goods receipt (GoodsReceiptId / Number / Status), DeliveredDate, CanReceive and
-- CloseBlockedReason (fn_Container_CloseBlock) at the end of the row; the days at the port stop at the Delivery when
-- nothing is received yet (edge case 29).
-- (54) from the body of script 27: the fill from the items' Container units instead of MaxUnits / UtilizationPct.
CREATE OR ALTER PROCEDURE logistics.usp_Container_Search
    @Search              NVARCHAR(100) = NULL,   -- ref, container no., B/L, vessel, PO / PI no., commercial invoice, supplier
    @ContainerRef        NVARCHAR(30)  = NULL,
    @ContainerNo         NVARCHAR(20)  = NULL,
    @SupplierId          INT           = NULL,
    @PurchaseDocumentId  INT           = NULL,   -- a purchase ORDER or a purchase INVOICE linked to the container
    @PurchaseOrderId     INT           = NULL,   -- containers carrying lines of this order
    @CommercialInvoiceNo NVARCHAR(50)  = NULL,
    @ItemId              INT           = NULL,
    @BlNo                NVARCHAR(30)  = NULL,
    @Status              TINYINT       = NULL,
    @PortId              INT           = NULL,
    @WarehouseId         INT           = NULL,
    @BranchId            INT           = NULL,
    @MovementId          INT           = NULL,   -- containers of this movement
    @OrderMonthKey       INT           = NULL,   -- e.g. 202601
    @DateFrom            DATE          = NULL,   -- order date
    @DateTo              DATE          = NULL,
    @SortColumn          NVARCHAR(30)  = N'OrderDate',  -- ContainerRef | ContainerNo | OrderDate | DispatchDate | Eta | Status | CreatedAtUtc
    @SortDirection       NVARCHAR(4)   = N'DESC',
    @PageNumber          INT           = 1,
    @PageSize            INT           = 10,
    @DeliveredNotReceived BIT          = 0       -- (65) 1 = delivered (or with a draft receipt) and not received yet
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @ContainerRef = NULLIF(LTRIM(RTRIM(@ContainerRef)), N'');
    SET @ContainerNo = NULLIF(LTRIM(RTRIM(@ContainerNo)), N'');
    SET @CommercialInvoiceNo = NULLIF(LTRIM(RTRIM(@CommercialInvoiceNo)), N'');
    SET @BlNo = NULLIF(LTRIM(RTRIM(@BlNo)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ContainerRef', N'ContainerNo', N'OrderDate', N'DispatchDate', N'Eta', N'Status', N'CreatedAtUtc')
        SET @SortColumn = N'OrderDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT c.Id, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, ct.TypeName AS ContainerTypeName,
           c.OrderDate, c.OrderMonthKey, OrderMonth = FORMAT(c.OrderDate, N'MMM-yyyy', N'en-US'),
           c.BranchId, b.BranchCode, b.BranchName, c.WarehouseId, w.WarehouseCode, w.WarehouseName,
           c.PurchaseOrderId, mpo.DocumentNumber AS PurchaseOrderNumber,
           OrderCount = ISNULL(po.OrderCount, 0),
           OrderNumbers = CASE WHEN ISNULL(po.OrderCount, 0) = 0 THEN NULL
                               WHEN po.OrderCount = 1 THEN po.FirstOrder
                               ELSE po.FirstOrder + N' +' + CAST(po.OrderCount - 1 AS NVARCHAR(10)) END,
           SupplierCount = ISNULL(po.SupplierCount, 0),
           SupplierNames = CASE WHEN ISNULL(po.SupplierCount, 0) = 0 THEN NULL
                                WHEN po.SupplierCount = 1 THEN po.FirstSupplier
                                ELSE po.FirstSupplier + N' +' + CAST(po.SupplierCount - 1 AS NVARCHAR(10)) END,
           InvoiceCount = ISNULL(inv.InvoiceCount, 0),
           InvoiceNumbers = CASE WHEN ISNULL(inv.InvoiceCount, 0) = 0 THEN NULL
                                 WHEN inv.InvoiceCount = 1 THEN inv.FirstInvoice
                                 ELSE inv.FirstInvoice + N' +' + CAST(inv.InvoiceCount - 1 AS NVARCHAR(10)) END,
           CommercialInvoiceNos = CASE WHEN inv.CiCount = 1 THEN inv.FirstCi
                                       WHEN inv.CiCount > 1 THEN inv.FirstCi + N' +' + CAST(inv.CiCount - 1 AS NVARCHAR(10)) END,
           ExporterReferences = CASE WHEN inv.ErCount = 1 THEN inv.FirstEr
                                     WHEN inv.ErCount > 1 THEN inv.FirstEr + N' +' + CAST(inv.ErCount - 1 AS NVARCHAR(10)) END,
           ItemCount = ISNULL(ln.ItemCount, 0),
           ItemSummary = CASE WHEN ISNULL(ln.ItemCount, 0) = 0 THEN NULL
                              WHEN ln.ItemCount = 1 THEN ln.FirstItem
                              ELSE N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           TotalQtyBase = ISNULL(ln.Qty, 0),
           InvoicedQtyBase = ISNULL(inv.PostedQty, 0),
           InvoicingStatus = CASE WHEN ISNULL(inv.PostedQty, 0) = 0 THEN 0
                                  WHEN inv.PostedQty >= ISNULL(ln.Qty, 0) THEN 2 ELSE 1 END,     -- 0 none, 1 partly, 2 fully (posted)
           TotalReceivedBase = c.TotalReceivedBase, c.TotalOilQty,
           fl.FillPct, fl.CapacityKnown, fl.MissingContainerUnitItems, fl.RemainingPcs, fl.IsOverCapacity,
           c.BlNo, c.BlDate, c.DispatchDate, c.Eta, c.ActualPortArrival, c.CustomsReleaseDate, c.OffloadedDate,
           c.FreeDays, c.LastFreeDay,
           DaysAtPort = CASE WHEN c.ActualPortArrival IS NOT NULL      -- (65) up to the receipt, else the Delivery, else today
                             THEN DATEDIFF(DAY, c.ActualPortArrival, COALESCE(c.OffloadedDate, dl.EndDate, CAST(SYSUTCDATETIME() AS DATE))) END,
           c.CurrentLocation, c.Status, c.StatusNote,
           CurrentMovementId = mv.Id, CurrentMovementNo = mv.MovementNo, CurrentMovementStatus = mv.Status,
           ChargesPostedBase = ISNULL(chg.Posted, 0), ChargesDraftBase = ISNULL(chg.Draft, 0),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ContainerId = c.Id),
           pl.PortName AS PortOfLoadingName, pd.PortName AS PortOfDestinationName,
           c.CreatedAtUtc, c.CreatedBy, cu.FullName AS CreatedByName, c.UpdatedAtUtc, c.RowVersion,
           COUNT(*) OVER () AS TotalCount,
           -- (65) goods receipts
           rb.ReceivedBy, rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus,
           DeliveredDate = dl.EndDate,
           CanReceive = CAST(CASE WHEN c.Status BETWEEN 2 AND 5 AND rb.GoodsReceiptId IS NULL THEN 1 ELSE 0 END AS BIT),
           CloseBlockedReason = cb.Reason
    FROM logistics.Containers c
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN purchase.PurchaseDocuments mpo ON mpo.Id = c.PurchaseOrderId
    LEFT  JOIN security.Users cu            ON cu.Id = c.CreatedBy
    CROSS APPLY logistics.fn_ContainerFill(c.Id) fl
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb      -- (65) who received it; its open goods receipt
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl    -- (65) its latest completed Delivery
    OUTER APPLY (SELECT b.Reason FROM logistics.fn_Container_CloseBlock(c.Id) b WHERE c.Status = 6) cb  -- (65) why not Close
    OUTER APPLY (SELECT OrderCount = COUNT(DISTINCT cl.PurchaseOrderId), SupplierCount = COUNT(DISTINCT d.SupplierId),
                        FirstOrder = MIN(d.DocumentNumber), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = c.Id) po
    OUTER APPLY (SELECT InvoiceCount = COUNT(DISTINCT d.Id),
                        CiCount = COUNT(DISTINCT d.CommercialInvoiceNo), ErCount = COUNT(DISTINCT d.ExporterReference),
                        FirstInvoice = MIN(d.DocumentNumber), FirstCi = MIN(d.CommercialInvoiceNo), FirstEr = MIN(d.ExporterReference),
                        PostedQty = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase ELSE 0 END)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                 INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                 WHERE cl.ContainerId = c.Id AND d.Status <> 3) inv
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), Qty = SUM(cl.QuantityBase), FirstItem = MIN(i.ItemName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 WHERE cl.ContainerId = c.Id) ln
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN ch.Status = 2 THEN ch.AmountBase END),
                        Draft  = SUM(CASE WHEN ch.Status = 1 THEN ch.AmountBase END)
                 FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id) chg
    OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, m.Status
                 FROM logistics.MovementContainers mc
                 INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                 WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)
                 ORDER BY CASE WHEN m.Status = 2 THEN 0 ELSE 1 END, COALESCE(m.EndDate, m.StartDate) DESC, m.Id DESC) mv
    WHERE (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
           OR c.BlNo LIKE N'%' + @Search + N'%' OR c.VesselName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                      INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
                      WHERE cl.ContainerId = c.Id AND (d.DocumentNumber LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%'))
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                      INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                      WHERE cl.ContainerId = c.Id AND d.Status <> 3
                        AND (d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.CommercialInvoiceNo LIKE N'%' + @Search + N'%'
                             OR d.ExporterReference LIKE N'%' + @Search + N'%')))
      AND (@ContainerRef IS NULL OR c.ContainerRef LIKE N'%' + @ContainerRef + N'%')
      AND (@ContainerNo IS NULL OR c.ContainerNo LIKE N'%' + @ContainerNo + N'%')
      AND (@BlNo IS NULL OR c.BlNo LIKE N'%' + @BlNo + N'%')
      AND (@Status IS NULL OR c.Status = @Status)
      AND (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR c.WarehouseId = @WarehouseId)
      AND (@PortId IS NULL OR c.PortOfLoadingId = @PortId OR c.PortOfDestinationId = @PortId OR c.FinalDestinationId = @PortId)
      AND (@OrderMonthKey IS NULL OR c.OrderMonthKey = @OrderMonthKey)
      AND (@DateFrom IS NULL OR c.OrderDate >= @DateFrom)
      AND (@DateTo IS NULL OR c.OrderDate <= @DateTo)
      AND (@SupplierId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                          INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                                          WHERE cl.ContainerId = c.Id AND d.SupplierId = @SupplierId))
      AND (@PurchaseOrderId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.PurchaseOrderId = @PurchaseOrderId))
      AND (@PurchaseDocumentId IS NULL
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.PurchaseOrderId = @PurchaseDocumentId)
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                      WHERE cl.ContainerId = c.Id AND pil.DocumentId = @PurchaseDocumentId))
      AND (@CommercialInvoiceNo IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                                   INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                                                   INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                                                   WHERE cl.ContainerId = c.Id AND d.Status <> 3
                                                     AND d.CommercialInvoiceNo LIKE N'%' + @CommercialInvoiceNo + N'%'))
      AND (@ItemId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.ItemId = @ItemId))
      AND (@MovementId IS NULL OR EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.ContainerId = c.Id AND mc.MovementId = @MovementId))
      AND (ISNULL(@DeliveredNotReceived, 0) = 0
           OR (c.Status BETWEEN 2 AND 5 AND ISNULL(rb.ReceivedBy, N'') <> N'GRN'
               AND (dl.MovementId IS NOT NULL OR rb.GoodsReceiptStatus = 1)))
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ContainerNo' THEN c.ContainerNo END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ContainerNo' THEN c.ContainerNo END END DESC,
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'OrderDate' THEN c.OrderDate WHEN N'DispatchDate' THEN c.DispatchDate WHEN N'Eta' THEN c.Eta END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'OrderDate' THEN c.OrderDate WHEN N'DispatchDate' THEN c.DispatchDate WHEN N'Eta' THEN c.Eta END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(c.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(c.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END DESC,
        c.OrderDate DESC, c.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

/* ================================================================== 18. The tracking board: the days at the port stop at the Delivery */

-- Re-created (65) from the body of script 27: the days at the port stop at the latest completed Delivery while the
-- goods wait for their receipt (edge case 29: the free time is over once the container left the port); + DeliveredDate,
-- ReceivedBy and the open goods receipt at the end of the containers' set. The legs are unchanged.
-- Tracking board: open containers (and those offloaded during the last @OffloadedDays days) with their route legs.
CREATE OR ALTER PROCEDURE logistics.usp_Container_Tracking
    @ContainerId   INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @OffloadedDays INT           = 30
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Ids TABLE (Id INT PRIMARY KEY);
    INSERT INTO @Ids (Id)
    SELECT c.Id FROM logistics.Containers c
    WHERE (@ContainerId IS NULL OR c.Id = @ContainerId)
      AND (@ContainerId IS NOT NULL OR c.Status IN (2, 3, 4, 5)
           OR (c.Status IN (6, 7) AND c.OffloadedDate >= DATEADD(DAY, -ISNULL(@OffloadedDays, 30), @Today)))
      AND (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
           OR c.BlNo LIKE N'%' + @Search + N'%' OR c.VesselName LIKE N'%' + @Search + N'%');

    -- 1: containers
    SELECT c.Id, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, c.Status, c.CurrentLocation,
           c.DispatchDate, c.Eta, c.ActualPortArrival, c.CustomsReleaseDate, c.OffloadedDate, c.LastFreeDay,
           DaysAtPort = CASE WHEN c.ActualPortArrival IS NOT NULL      -- (65) up to the receipt, else the Delivery, else today
                             THEN DATEDIFF(DAY, c.ActualPortArrival, COALESCE(c.OffloadedDate, dl.EndDate, @Today)) END,
           c.TotalAllocatedBase, c.TotalOilQty,
           ItemSummary = CASE WHEN ln.ItemCount = 1 THEN ln.FirstItem WHEN ln.ItemCount > 1 THEN N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           SupplierName = ln.FirstSupplier,
           pl.PortName AS PortOfLoadingName, pd.PortName AS PortOfDestinationName, fd.PortName AS FinalDestinationName,
           w.WarehouseName,
           DeliveredDate = dl.EndDate,                                  -- (65) goods receipts
           rb.ReceivedBy, rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus
    FROM @Ids x
    INNER JOIN logistics.Containers c       ON c.Id = x.Id
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN masterdata.Ports fd          ON fd.Id = c.FinalDestinationId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb      -- (65) who received it; its open goods receipt
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl    -- (65) its latest completed Delivery
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), FirstItem = MIN(i.ItemName), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = c.Id) ln
    ORDER BY c.Status, c.Eta, c.ContainerRef;

    -- 2: legs in route order; ProgressPct places the container on an in-progress leg (elapsed / planned duration)
    SELECT mc.ContainerId, m.Id AS MovementId, m.MovementNo,
           Seq = ROW_NUMBER() OVER (PARTITION BY mc.ContainerId ORDER BY COALESCE(m.StartDate, m.PlannedDate, CAST(m.CreatedAtUtc AS DATE)), m.Id),
           mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.Kind AS FromKind, fp.CountryCode AS FromCountry,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.Kind AS ToKind, tp.CountryCode AS ToCountry,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status,
           cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo,
           ProgressPct = CASE WHEN m.Status = 3 THEN 100
                              WHEN m.Status = 1 THEN 0
                              WHEN m.Eta IS NOT NULL AND m.StartDate IS NOT NULL AND m.Eta > m.StartDate
                                   THEN CASE WHEN DATEDIFF(DAY, m.StartDate, @Today) <= 0 THEN 0
                                             WHEN DATEDIFF(DAY, m.StartDate, @Today) * 100 / DATEDIFF(DAY, m.StartDate, m.Eta) > 95 THEN 95
                                             ELSE DATEDIFF(DAY, m.StartDate, @Today) * 100 / DATEDIFF(DAY, m.StartDate, m.Eta) END
                              ELSE 50 END,
           IsLate = CAST(CASE WHEN m.Status IN (1, 2) AND m.Eta < @Today THEN 1 ELSE 0 END AS BIT)
    FROM @Ids x
    INNER JOIN logistics.MovementContainers mc ON mc.ContainerId = x.Id
    INNER JOIN logistics.Movements m           ON m.Id = mc.MovementId AND m.Status <> 4
    INNER JOIN masterdata.MovementTypes mt     ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp             ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp             ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp           ON cp.Id = m.CarrierPartyId
    ORDER BY mc.ContainerId, Seq;
END
GO

/* ================================================================== 19. Movement Get: the containers' goods receipts */

-- Re-created (65) from the body of script 27: the container set + the open goods receipt, the warehouse its Delivery
-- draft would take, and the automatic draft this movement's cancel would delete (rules 5 and 22).
-- Four result sets: 1 header, 2 containers, 3 charges linked to the movement, 4 attachments linked to the movement.
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
           -- choose", "already has GRN-..."). WarehouseInBranch = the container's warehouse is active and of its branch,
           -- the rule of usp_GoodsReceipt_CreateForContainer. AutoDraftOfThisMovement = the receipt is a draft made by
           -- this movement's completion: cancelling the movement deletes it (usp_Movement_SetStatus); the Cancel dialog
           -- names those edited since (GoodsReceiptUpdatedAtUtc / ByName, NULL when never edited).
           GoodsReceiptId = gr.GoodsReceiptId, GoodsReceiptNumber = gr.GoodsReceiptNumber, GoodsReceiptStatus = gr.GoodsReceiptStatus,
           WarehouseCode = w.WarehouseCode,
           WarehouseInBranch = CAST(CASE WHEN w.IsActive = 1 AND w.BranchId = c.BranchId THEN 1 ELSE 0 END AS BIT),
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

/* ================================================================== 20. Item costs: the last receipt is a goods receipt */

-- Re-created (65) from the body of script 27: LastCost / FobCost / LastSupplierId / LastPurchaseAtUtc come from the
-- latest of (a) a local invoice posted before goods receipts (ReceiptMode 1, UsesGoodsReceipts 0: it received its goods
-- when posted), (b) a container offloaded the old way (fn_Container_ReceivedBy = 'Offload'), (c) a posted goods receipt
-- line with pieces - a container line's cost is the container line's (cl.LandedCostBase / FobCostBase, after its late
-- charges), another line's its own current cost (after its true-ups); its supplier is the line's (a container of
-- several suppliers), its date the receipt's posting. A line received without an order or an invoice (manual) counts
-- only once matched to an invoice: its typed cost is not a purchase price. An invoice posted after the switch receives
-- nothing, so it is not a source any more. The replay of the average is unchanged.
-- Replays the ledger (documents without reversal, matched by family + TYPE + id) + inventory cost
-- adjustments in date order -> exact moving average; LastCost / FobCost / last supplier from the latest RECEIPT.
-- @ItemId NULL = every item (maintenance).
CREATE OR ALTER PROCEDURE inventory.usp_Item_RebuildCosts
    @ItemId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Events TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ItemId INT, Qty INT, Cost DECIMAL(18,6), Amount DECIMAL(18,2));
    INSERT INTO @Events (ItemId, Qty, Cost, Amount)
    SELECT x.ItemId, x.Qty, x.Cost, x.Amount
    FROM
    (
        SELECT m.ItemId, EventDate = m.MovementDate, Src = 1, SrcId = m.Id, Qty = m.QuantityBase, Cost = m.UnitCostBase, Amount = CAST(NULL AS DECIMAL(18,2))
        FROM inventory.StockMovements m
        WHERE (@ItemId IS NULL OR m.ItemId = @ItemId)
          AND NOT EXISTS (SELECT 1 FROM inventory.StockMovements r WHERE r.DocumentFamily = m.DocumentFamily AND r.DocumentTypeCode = m.DocumentTypeCode
                                                                     AND r.DocumentId = m.DocumentId AND r.IsReversal = 1
                                                                     AND (m.DocumentTypeCode <> N'CNT' OR r.DocumentNumber = m.DocumentNumber))
        UNION ALL
        SELECT c.ItemId, c.AdjustmentDate, 2, CAST(c.Id AS INT), 0, NULL, c.AmountBase
        FROM inventory.CostAdjustments c
        WHERE c.Kind = N'Inventory' AND (@ItemId IS NULL OR c.ItemId = @ItemId)
    ) x
    ORDER BY x.ItemId, x.EventDate, x.Src, x.SrcId;

    DECLARE @Result TABLE (ItemId INT PRIMARY KEY, AverageCost DECIMAL(18,6));
    DECLARE @CurItem INT = NULL, @OnHand DECIMAL(18,6) = 0, @Avg DECIMAL(18,6) = 0;
    DECLARE @EItem INT, @EQty INT, @ECost DECIMAL(18,6), @EAmount DECIMAL(18,2);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT ItemId, Qty, Cost, Amount FROM @Events ORDER BY Seq;
    OPEN cur;
    FETCH NEXT FROM cur INTO @EItem, @EQty, @ECost, @EAmount;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @CurItem IS NULL OR @CurItem <> @EItem
        BEGIN
            IF @CurItem IS NOT NULL INSERT INTO @Result (ItemId, AverageCost) VALUES (@CurItem, @Avg);
            SELECT @CurItem = @EItem, @OnHand = 0, @Avg = 0;
        END

        IF @EAmount IS NOT NULL                                   -- inventory value adjustment (LCA)
            SET @Avg = CASE WHEN @OnHand > 0 THEN @Avg + @EAmount / @OnHand ELSE @Avg END;
        ELSE IF @EQty > 0                                         -- receipt
        BEGIN
            SET @Avg = CASE WHEN @OnHand + @EQty > 0 THEN ((CASE WHEN @OnHand > 0 THEN @OnHand ELSE 0 END) * @Avg + @EQty * ISNULL(@ECost, @Avg)) / ((CASE WHEN @OnHand > 0 THEN @OnHand ELSE 0 END) + @EQty) ELSE @Avg END;
            SET @OnHand = @OnHand + @EQty;
        END
        ELSE                                                      -- issue: average unchanged
            SET @OnHand = @OnHand + @EQty;

        FETCH NEXT FROM cur INTO @EItem, @EQty, @ECost, @EAmount;
    END
    CLOSE cur; DEALLOCATE cur;
    IF @CurItem IS NOT NULL INSERT INTO @Result (ItemId, AverageCost) VALUES (@CurItem, @Avg);

    -- Items with no remaining events (everything cancelled) fall back to 0.
    UPDATE i SET AverageCost = ISNULL(r.AverageCost, 0)
    FROM inventory.Items i
    LEFT JOIN @Result r ON r.ItemId = i.Id
    WHERE (@ItemId IS NULL OR i.Id = @ItemId);

    UPDATE i
    SET LastCost = x.Landed, FobCost = x.Fob, LastSupplierId = x.SupplierId, LastPurchaseAtUtc = x.ReceivedAtUtc
    FROM inventory.Items i
    OUTER APPLY (SELECT TOP (1) r.Landed, r.Fob, r.SupplierId, r.ReceivedAtUtc
                 FROM (-- (65) (a) a local invoice posted before goods receipts (it received its goods when posted)
                       SELECT Landed = l.UnitCostBase, Fob = l.FobCostBase, d.SupplierId, ReceivedAtUtc = d.PostedAtUtc, Tie = l.Id
                       FROM purchase.PurchaseDocumentLines l
                       INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
                       INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                       WHERE dt.Code = N'PINV' AND d.Status = 2 AND d.ReceiptMode = 1 AND d.UsesGoodsReceipts = 0 AND l.ItemId = i.Id
                       UNION ALL
                       -- (65) (b) a container offloaded before goods receipts (a container received with one is (c))
                       SELECT cl.LandedCostBase, cl.FobCostBase, po.SupplierId, c.OffloadedAtUtc, cl.Id
                       FROM logistics.ContainerLines cl
                       INNER JOIN logistics.Containers c        ON c.Id = cl.ContainerId
                       INNER JOIN purchase.PurchaseDocuments po ON po.Id = cl.PurchaseOrderId
                       CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
                       WHERE rb.ReceivedBy = N'Offload' AND cl.ItemId = i.Id AND cl.ReceivedQuantityBase > 0
                       UNION ALL
                       -- (65) (c) a posted goods receipt line with pieces; a manual line only once matched to an invoice
                       SELECT CASE WHEN gl.ContainerLineId IS NOT NULL THEN gcl.LandedCostBase ELSE gl.UnitCostBase END,
                              CASE WHEN gl.ContainerLineId IS NOT NULL THEN gcl.FobCostBase ELSE gl.FobCostBase END,
                              gl.SupplierId, g.PostedAtUtc, gl.Id
                       FROM purchase.GoodsReceiptLines gl
                       INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId AND g.Status = 2
                       LEFT  JOIN logistics.ContainerLines gcl  ON gcl.Id = gl.ContainerLineId
                       WHERE gl.ItemId = i.Id AND gl.QuantityBase > 0
                         AND NOT (gl.PoLineId IS NULL AND gl.InvoiceLineId IS NULL AND gl.InvoicedBase = 0)) r
                 ORDER BY r.ReceivedAtUtc DESC, r.Tie DESC) x
    WHERE (@ItemId IS NULL OR i.Id = @ItemId);
END
GO

/* ================================================================== 21. Item stock statement: goods receipt rows */

-- Re-created (65) from the body of script 58: a goods receipt (type GRN) is not a purchase document, so the
-- purchase-document join leaves it out (its id is a goods receipt id, not a document id). Its counterparty is the
-- supplier of the receipt line (a container of several suppliers has one per line), else of the receipt; and the new
-- column SourceReference names where the goods came from: the container, else the order, else the invoice (a receipt
-- made from an invoice without an order). NULL on every other row.
CREATE OR ALTER PROCEDURE inventory.usp_Item_StockStatement
    @ItemId      INT,
    @DateFrom    DATE = NULL,
    @DateTo      DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Opening INT =
        CASE WHEN @DateFrom IS NULL THEN 0 ELSE
            (SELECT ISNULL(SUM(m.QuantityBase), 0) FROM inventory.StockMovements m
             WHERE m.ItemId = @ItemId AND m.MovementDate < @DateFrom) END;

    SELECT OpeningBase = @Opening;

    SELECT m.Id, m.MovementDate, m.DocumentFamily, m.DocumentTypeCode, DocumentTypeName = dt.Name,
           m.DocumentId, m.DocumentNumber, m.IsReversal, m.ReasonCode, m.ExpiryDate,
           m.WarehouseId, w.WarehouseCode, w.WarehouseName, br.BranchName,
           QuantityIn  = CASE WHEN m.QuantityBase > 0 THEN m.QuantityBase ELSE 0 END,
           QuantityOut = CASE WHEN m.QuantityBase < 0 THEN -m.QuantityBase ELSE 0 END,
           Balance     = @Opening + SUM(m.QuantityBase) OVER (ORDER BY m.MovementDate, m.Id ROWS UNBOUNDED PRECEDING),
           m.UnitCostBase,
           -- who the stock went to or came from: the client of a sale, the supplier of a purchase
           Counterparty = COALESCE(cl.PartyName, sp.PartyName),
           -- (65) a goods receipt's source: its container, else its order, else its invoice
           SourceReference = CASE WHEN gr.Id IS NOT NULL THEN COALESCE(gc.ContainerRef, gpo.DocumentNumber, gpi.DocumentNumber) END,
           CreatedByName = u.FullName
    FROM inventory.StockMovements m
    INNER JOIN masterdata.Warehouses w ON w.Id = m.WarehouseId
    INNER JOIN masterdata.Branches br  ON br.Id = w.BranchId
    LEFT JOIN inventory.DocumentTypes dt ON dt.Code = m.DocumentTypeCode
    LEFT JOIN sales.SalesDocuments sd ON m.DocumentFamily = N'Sales' AND sd.Id = m.DocumentId
    LEFT JOIN masterdata.Parties cl ON cl.Id = sd.ClientId
    LEFT JOIN purchase.PurchaseDocuments pd ON m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode NOT IN (N'CNT', N'GRN') AND pd.Id = m.DocumentId
    -- (65) a goods receipt row: the receipt, its line (the stock row's line), its container, order and invoice
    LEFT JOIN purchase.GoodsReceipts gr ON m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'GRN' AND gr.Id = m.DocumentId
    LEFT JOIN purchase.GoodsReceiptLines grl ON grl.Id = m.DocumentLineId AND grl.GoodsReceiptId = gr.Id
    LEFT JOIN logistics.Containers gc ON gc.Id = gr.ContainerId
    LEFT JOIN purchase.PurchaseDocuments gpo ON gpo.Id = COALESCE(grl.PurchaseOrderId, gr.PurchaseOrderId)
    LEFT JOIN purchase.PurchaseDocuments gpi ON gpi.Id = gr.PurchaseInvoiceId
    LEFT JOIN masterdata.Parties sp ON sp.Id = COALESCE(pd.SupplierId, grl.SupplierId, gr.SupplierId)
    LEFT JOIN security.Users u ON u.Id = m.CreatedBy
    WHERE m.ItemId = @ItemId
      AND (@DateFrom IS NULL OR m.MovementDate >= @DateFrom)
      AND (@DateTo IS NULL OR m.MovementDate < DATEADD(DAY, 1, @DateTo))
    ORDER BY m.MovementDate, m.Id;
END
GO

/* ================================================================== 22. What is still to come: Shortages and the item's orders */

-- Re-created (65) from the body of script 62: what the orders and invoices still bring is rule 25 - the outstanding
-- of the order lines of open and closed orders (purchase.fn_PoLine_Progress.OutstandingBase: ordered, or invoiced once
-- the order is closed, less received and settled short; never below 0), plus the posted invoices WITHOUT an order
-- whose goods come with goods receipts (UsesGoodsReceipts = 1), invoiced - received. An invoice of an order is
-- counted on its order (the "pending" shipped-in-containers invoice of before is replaced by the order's outstanding,
-- which already held it). Transit, the stock, the sales and the units are unchanged.
CREATE OR ALTER FUNCTION inventory.fn_Shortage_Live (@WarehouseId INT, @MonthsOfHistory INT)
RETURNS TABLE
AS
RETURN
(
    /* (62) THE WAREHOUSE AND EVERY WAREHOUSE UNDER IT. A plan for a parent counts the stock, sales,
       orders and containers of its whole tree; a warehouse with nothing under it is just itself.
       The depth guard stops a cycle left by older data instead of recursing for ever. */
    WITH tree AS
    (
        SELECT w.Id, 0 AS Depth FROM masterdata.Warehouses w WHERE w.Id = @WarehouseId
        UNION ALL
        SELECT w.Id, t.Depth + 1 FROM masterdata.Warehouses w INNER JOIN tree t ON w.ParentId = t.Id WHERE t.Depth < 20
    )
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName, i.BrandId, i.ItemFamilyId, i.IsBivac,
           i.DefaultSupplierId, i.LastSupplierId, i.MinQuantity, i.MaxQuantity, i.LastCost, i.AverageCost, i.LeadTimeDays,
           ItemPcPerContainer = cnt.PackingFormula,                         -- the item's Container unit, NULL when none
           PcPerContainerFromUnit = CAST(CASE WHEN cnt.PackingFormula IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           CurrentInventoryBase     = ISNULL((SELECT SUM(m.QuantityBase) FROM inventory.StockMovements m
                                              WHERE m.ItemId = i.Id AND m.WarehouseId IN (SELECT t.Id FROM tree t)), 0),
           TransitBase              = ISNULL(tr.Transit, 0),
           OutstandingOrderBase     = CASE WHEN ISNULL(po.PoOpen, 0) + ISNULL(po.InvPending, 0) - ISNULL(tr.Transit, 0) > 0
                                           THEN ISNULL(po.PoOpen, 0) + ISNULL(po.InvPending, 0) - ISNULL(tr.Transit, 0) ELSE 0 END,
           ExpectedMonthlySalesBase = CONVERT(DECIMAL(18,2), CAST(ISNULL(s.Sold, 0) AS DECIMAL(18,4)) / NULLIF(@MonthsOfHistory, 0)),
           SoldInPeriodBase         = ISNULL(s.Sold, 0),
           PurchaseItemUnitId       = pu.ItemUnitId,
           PurchaseUnitName         = pu.UnitTypeName,
           PurchasePackingFormula   = pu.PackingFormula
    FROM inventory.Items i
    OUTER APPLY
    (
        -- (65) rule 25: open and closed orders still to receive + invoices without an order not received yet
        SELECT PoOpen     = SUM(CASE WHEN dt.Code = N'PO'   THEN ISNULL(pp.OutstandingBase, 0) ELSE 0 END),
               InvPending = SUM(CASE WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReceivedQuantityBase ELSE 0 END)
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
        INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
        OUTER APPLY (SELECT p.OutstandingBase FROM purchase.fn_PoLine_Progress(d.Id) p WHERE p.PoLineId = l.Id) pp
        WHERE l.ItemId = i.Id AND l.WarehouseId IN (SELECT t.Id FROM tree t)
          AND ((dt.Code = N'PO'   AND d.Status IN (2, 4))
            OR (dt.Code = N'PINV' AND d.Status IN (2, 4) AND d.UsesGoodsReceipts = 1 AND l.SourceLineId IS NULL
                AND l.QuantityBase > l.ReceivedQuantityBase))
    ) po
    OUTER APPLY
    (
        -- loaded into a container that has left the supplier and is not offloaded yet
        SELECT Transit = SUM(cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0))
        FROM logistics.ContainerLines cl
        INNER JOIN logistics.Containers c             ON c.Id = cl.ContainerId
        INNER JOIN purchase.PurchaseDocumentLines pl  ON pl.Id = cl.PoLineId
        WHERE cl.ItemId = i.Id AND c.Status IN (3, 4, 5)
          AND pl.WarehouseId IN (SELECT t.Id FROM tree t)                  -- the order's warehouse, like the open order / invoice quantities
          AND cl.QuantityBase > ISNULL(cl.ReceivedQuantityBase, 0)
    ) tr
    OUTER APPLY
    (
        SELECT Sold = SUM(-m.QuantityBase)
        FROM inventory.StockMovements m
        WHERE m.ItemId = i.Id AND m.WarehouseId IN (SELECT t.Id FROM tree t) AND m.DocumentFamily = N'Sales'
          AND m.MovementDate >= DATEADD(MONTH, -@MonthsOfHistory, CAST(SYSUTCDATETIME() AS DATE))
    ) s
    OUTER APPLY
    (
        SELECT TOP (1) u.Id AS ItemUnitId, u.PackingFormula, t.UnitTypeName
        FROM inventory.ItemUnits u INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
        WHERE u.ItemId = i.Id ORDER BY u.IsPurchaseUnit DESC, u.IsBaseUnit DESC
    ) pu
    OUTER APPLY
    (
        SELECT TOP (1) u.PackingFormula
        FROM inventory.ItemUnits u INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
        WHERE u.ItemId = i.Id AND t.IsContainer = 1
    ) cnt
    WHERE i.IsActive = 1
);
GO

-- Re-created (65) from the body of script 59: RECEIVED is now what goods receipts (and the receipts made before them)
-- brought in, GoodsReceivedBase; INVOICED (ReceivedQuantityBase, the old "received") and SHORT (settled short, nothing
-- more will come) are new columns. STILL TO COME is rule 25, the same number Shortages counts: the order lines'
-- fn_PoLine_Progress.OutstandingBase on an open (Posted) or Closed order - a closed order may still bring what was
-- invoiced and not received; a draft, waiting or cancelled order brings nothing.
CREATE OR ALTER PROCEDURE inventory.usp_Item_PurchaseOrders
    @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id AS DocumentId, d.DocumentNumber, d.DocumentDate, d.ExpectedDate, d.Status AS StatusCode,
           s.PartyCode AS SupplierCode, s.PartyName AS SupplierName, br.BranchName,
           c.CurrencyCode, c.DecimalPlaces,
           x.OrderedBase, x.ReceivedBase, x.InvoicedBase, x.ShortBase,                       -- (65) received = goods received
           OutstandingBase = CASE WHEN d.Status IN (2, 4) THEN x.OutstandingBase ELSE 0 END, -- (65) rule 25
           x.Amount
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes t ON t.Id = d.DocumentTypeId AND t.Code = N'PO'
    CROSS APPLY (SELECT OrderedBase = SUM(l.QuantityBase), ReceivedBase = SUM(l.GoodsReceivedBase),
                        InvoicedBase = SUM(l.ReceivedQuantityBase), ShortBase = SUM(l.GoodsShortBase),
                        OutstandingBase = SUM(p.OutstandingBase), Amount = SUM(l.LineTotal)
                 FROM purchase.PurchaseDocumentLines l
                 CROSS APPLY purchase.fn_PoLine_Progress(l.DocumentId) p
                 WHERE l.DocumentId = d.Id AND l.ItemId = @ItemId AND p.PoLineId = l.Id) x
    INNER JOIN masterdata.Parties s    ON s.Id = d.SupplierId
    INNER JOIN masterdata.Branches br  ON br.Id = d.BranchId
    INNER JOIN masterdata.Currencies c ON c.Id = d.CurrencyId
    WHERE x.OrderedBase IS NOT NULL
    ORDER BY d.DocumentDate DESC, d.Id DESC;
END
GO

/* ================================================================== 23. Landed cost adjustments on an invoice that uses goods receipts */

-- Re-created (65) from the body of script 27: an IMPORTED invoice takes no landed cost adjustment (67012) - one with a
-- line linked to a container, as before, and now also one "Shipped in containers" (ReceiptMode 2) whose lines are not
-- linked yet. Its goods are received through containers and goods receipts: an old one (posted before the switch)
-- would put the charge in the average at once on unrelated stock, then again in the cost of its goods when they are
-- received at the invoice's landed cost; a new one would have its unlinked lines matched to container receipt lines,
-- whose cost takes container charges only, so the charge would enter no cost. Late charges of an import go on its
-- containers (Container Charges). The text is the one the API repeats (LateChargeService).
CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Save
    @Id                INT            = NULL,
    @SourceInvoiceId   INT,
    @DocumentDate      DATE,
    @Notes             NVARCHAR(1000) = NULL,
    @Charges           purchase.tvp_PurchaseCharge READONLY,
    @ManualAllocations purchase.tvp_ManualAllocation READONLY,
    @RowVersion        BINARY(8)      = NULL,
    @UserId            INT            = NULL,
    @NewId             INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @DocumentDate IS NULL THROW 67000, 'Date is required.', 1;
    IF @DocumentDate > CAST(SYSUTCDATETIME() AS DATE) THROW 67000, 'Date cannot be in the future.', 1;

    DECLARE @InvStatus TINYINT, @InvType NVARCHAR(20), @BranchId INT, @BaseCurrency INT = (SELECT TOP (1) Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1);
    SELECT @InvStatus = d.Status, @InvType = dt.Code, @BranchId = d.BranchId
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceInvoiceId;
    IF @InvStatus IS NULL THROW 67011, 'Purchase invoice not found.', 1;
    IF @InvType <> N'PINV' OR @InvStatus <> 2 THROW 67011, 'Landed cost adjustments apply to POSTED purchase invoices only.', 1;
    -- (65) + "Shipped in containers" (ReceiptMode 2), linked or not
    IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceInvoiceId AND ReceiptMode = 2)
       OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @SourceInvoiceId AND ContainerLineId IS NOT NULL)
        THROW 67012, 'This invoice comes from containers: late charges are entered on the containers (Container Charges), not as a landed cost adjustment.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Charges) THROW 67000, 'At least one charge is required.', 1;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM purchase.LandedCostAdjustments WHERE Id = @Id);
        IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
        IF @Status <> 1 THROW 67005, 'Only draft adjustments can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 67004, 'This adjustment was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND SourceInvoiceId <> @SourceInvoiceId)
            THROW 67000, 'The invoice of an adjustment cannot be changed.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;
        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'LCA');
            EXEC inventory.usp_DocumentType_NextNumber N'LCA', @Number OUTPUT, @BranchId;
            INSERT INTO purchase.LandedCostAdjustments (DocumentTypeId, DocumentNumber, DocumentDate, BranchId, SourceInvoiceId, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @BranchId, @SourceInvoiceId, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
        END
        ELSE
            UPDATE purchase.LandedCostAdjustments SET DocumentDate = @DocumentDate, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;

        EXEC purchase.usp_PurchaseCharges_Write N'LCA', @Id, @DocumentDate, @BaseCurrency, @SourceInvoiceId, @Charges, @ManualAllocations, @UserId;

        UPDATE a SET TotalChargesBase = ISNULL((SELECT SUM(AmountBase) FROM purchase.PurchaseCharges WHERE DocumentKind = N'LCA' AND DocumentId = @Id AND IncludeInLandedCost = 1), 0)
        FROM purchase.LandedCostAdjustments a WHERE a.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (65) from the body of script 23. An invoice posted after the switch (UsesGoodsReceipts = 1) moved no
-- stock: its goods came, or will come, with goods receipts, whose cost is the invoice cost (rule 9). So an adjustment
-- on it changes the invoice lines' landed cost FIRST (allocated charges, landed cost: as before), then brings the
-- receipt lines matched to those invoice lines to their new cost (usp_GoodsReceipt_TrueUpCost, cause LCA): the part
-- still in company stock to the stock value, the rest to cost of sales, as GRNCOST rows - the average and the last
-- cost follow the receipts (usp_Item_RebuildCosts). It does NOT change the average directly, write LCA rows or set the
-- last cost: that would count the charges twice. Pieces not received yet take the charges when they are received.
-- The adjustment's lines keep what this did: received = the pieces of the line matched to receipts, net of returns,
-- the part in stock, and the stock / cost-of-sales portions of the true-up, shared over the lines by their matched
-- pieces. Invoices posted before the switch keep the current logic, but for their item costs: replayed
-- (usp_Item_RebuildCosts, as Cancel does) instead of "the last cost follows when this invoice is the item's latest
-- posted purchase" - since the switch the last cost, FOB cost and last supplier come from the latest RECEIPT (a goods
-- receipt included), and setting the last cost from an older invoice would overwrite the cost of goods received later.
-- Also (65): the matching lock first (usp_GoodsReceipt_LockMatching), and an imported invoice (linked to containers or
-- "Shipped in containers") refused again at posting (67012), for a draft saved before Save refused it.
-- Posting: allocate over the invoice lines, split between stock still on hand (inventory value, average recalculated)
-- and quantity already sold (COGS adjustment), update the invoice lines' landed cost, then the item costs.
CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- (65) lock order: the goods receipt matcher first, then rows - the true-up below reads the receipts of the
        --      invoice's groups, which a goods receipt or an invoice being posted writes
        EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @Status TINYINT, @InvoiceId INT, @Number NVARCHAR(30), @Date DATE, @BranchId INT;
        SELECT @Status = Status, @InvoiceId = SourceInvoiceId, @Number = DocumentNumber, @Date = DocumentDate, @BranchId = BranchId
        FROM purchase.LandedCostAdjustments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
        IF @Status <> 1 THROW 67010, 'Only draft adjustments can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 67004, 'This adjustment was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId AND Status = 2)
            THROW 67011, 'The purchase invoice is no longer posted.', 1;
        -- (65) an imported invoice, linked to containers or "Shipped in containers" (ReceiptMode 2): as Save refuses it
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId AND ReceiptMode = 2)
           OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId AND ContainerLineId IS NOT NULL)
            THROW 67012, 'This invoice comes from containers: late charges are entered on the containers (Container Charges), not as a landed cost adjustment.', 1;

        -- (65) an invoice whose goods come with goods receipts: the cost moves through the receipts
        DECLARE @UsesGoodsReceipts BIT =
            ISNULL((SELECT CAST(CASE WHEN dt.Code = N'PINV' AND d.UsesGoodsReceipts = 1 THEN 1 ELSE 0 END AS BIT)
                    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                    WHERE d.Id = @InvoiceId), 0);

        EXEC purchase.usp_PurchaseCharges_Allocate N'LCA', @Id, @InvoiceId;

        DECLARE @Rate DECIMAL(18,6) = (SELECT ExchangeRate FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId);

        DELETE FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id;
        INSERT INTO purchase.LandedCostAdjustmentLines (AdjustmentId, PurchaseLineId, ItemId, WarehouseId, ReceivedBase, NetReceivedBase, RemainingBase,
                                                        AllocatedBase, ExtraPerBaseUnit, InventoryPortionBase, CogsPortionBase, LandedCostBefore, LandedCostAfter)
        SELECT @Id, l.Id, l.ItemId, l.WarehouseId, l.QuantityBase, n.NetReceived, r.Remaining,
               a.Allocated, a.Allocated / l.QuantityBase,
               InvPortion = ROUND(a.Allocated / l.QuantityBase * r.Remaining, 2),
               CogsPortion = a.Allocated - ROUND(a.Allocated / l.QuantityBase * r.Remaining, 2),
               l.UnitCostBase,
               ((l.LineTotal / @Rate) + l.AllocatedChargesBase + a.Allocated) / l.QuantityBase
        FROM purchase.PurchaseDocumentLines l
        CROSS APPLY (SELECT Allocated = ISNULL((SELECT SUM(x.AmountBase) FROM purchase.PurchaseChargeAllocations x
                                                 INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                                                 WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'LCA' AND c.DocumentId = @Id AND c.IncludeInLandedCost = 1), 0)) a
        CROSS APPLY (SELECT NetReceived = l.QuantityBase - l.ReturnedQuantityBase) n
        CROSS APPLY (SELECT Remaining = CASE WHEN inventory.fn_StockOnHand(l.ItemId, l.WarehouseId) < n.NetReceived
                                             THEN CASE WHEN inventory.fn_StockOnHand(l.ItemId, l.WarehouseId) > 0 THEN inventory.fn_StockOnHand(l.ItemId, l.WarehouseId) ELSE 0 END
                                             ELSE n.NetReceived END) r
        WHERE l.DocumentId = @InvoiceId AND a.Allocated <> 0;

        -- Items with no stock at all: everything goes to COGS. (65) Older invoices only.
        UPDATE x SET CogsPortionBase = x.CogsPortionBase + x.InventoryPortionBase, InventoryPortionBase = 0
        FROM purchase.LandedCostAdjustmentLines x
        WHERE x.AdjustmentId = @Id AND inventory.fn_StockOnHand(x.ItemId, NULL) <= 0 AND @UsesGoodsReceipts = 0;

        -- Inventory value -> moving average (company-wide: value added / total on hand of the item). (65) Older invoices only.
        UPDATE i SET AverageCost = i.AverageCost + p.Inv / inventory.fn_StockOnHand(i.Id, NULL)
        FROM inventory.Items i
        INNER JOIN (SELECT ItemId, Inv = SUM(InventoryPortionBase) FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id GROUP BY ItemId) p ON p.ItemId = i.Id
        WHERE p.Inv <> 0 AND inventory.fn_StockOnHand(i.Id, NULL) > 0 AND @UsesGoodsReceipts = 0;

        -- Invoice lines / header carry the new landed cost.
        UPDATE l SET AllocatedChargesBase = l.AllocatedChargesBase + x.AllocatedBase, UnitCostBase = x.LandedCostAfter
        FROM purchase.PurchaseDocumentLines l INNER JOIN purchase.LandedCostAdjustmentLines x ON x.PurchaseLineId = l.Id
        WHERE x.AdjustmentId = @Id;
        UPDATE d SET TotalChargesBase = ISNULL(x.Charges, 0), TotalLandedCostBase = d.TotalAmountBase + ISNULL(x.Charges, 0)
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT SUM(AllocatedChargesBase) AS Charges FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId) x
        WHERE d.Id = @InvoiceId;

        -- Value ledger. (65) Older invoices only.
        INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
        SELECT DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@Date AS DATETIME2(3))),
               x.ItemId, x.WarehouseId, @BranchId, k.Kind, k.Amount, N'LCA', @Id, @Number, x.PurchaseLineId, @UserId
        FROM purchase.LandedCostAdjustmentLines x
        CROSS APPLY (VALUES (N'Inventory', x.InventoryPortionBase), (N'COGS', x.CogsPortionBase)) k (Kind, Amount)
        WHERE x.AdjustmentId = @Id AND k.Amount <> 0 AND @UsesGoodsReceipts = 0;

        -- (65) Older invoices: the ITEM COSTS REPLAYED from the ledger (usp_Item_RebuildCosts, as Cancel does) - the
        --      average with the rows just written, and the last cost, FOB cost and last supplier by the switch's rule: the
        --      latest RECEIPT, a goods receipt included. (Was: the last cost set to this invoice's when it is the item's
        --      latest posted invoice - since the switch that overwrote the cost of goods received later and left the FOB
        --      cost of another purchase beside it, or kept a stale one.) An invoice that uses goods receipts: the true-up
        --      below replays the items it adjusts.
        IF @UsesGoodsReceipts = 0
        BEGIN
            DECLARE @ItemId INT;
            DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id;
            OPEN items; FETCH NEXT FROM items INTO @ItemId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC inventory.usp_Item_RebuildCosts @ItemId;
                FETCH NEXT FROM items INTO @ItemId;
            END
            CLOSE items; DEALLOCATE items;
        END

        -- (65) AN INVOICE THAT USES GOODS RECEIPTS: the goods received against its adjusted lines are brought to their new
        --      cost (the invoice lines carry it now), and what that did is kept on the adjustment's lines.
        DECLARE @AdjAmount DECIMAL(18,2) = 0, @AdjInventory DECIMAL(18,2) = 0, @AdjCogs DECIMAL(18,2) = 0, @AdjLines INT = 0;
        IF @UsesGoodsReceipts = 1
        BEGIN
            DECLARE @ReceiptLines logistics.tvp_IdList;
            INSERT INTO @ReceiptLines (Id)
            SELECT DISTINCT m.GoodsReceiptLineId
            FROM purchase.GoodsReceiptInvoiceMatches m
            INNER JOIN purchase.LandedCostAdjustmentLines x ON x.PurchaseLineId = m.InvoiceLineId AND x.AdjustmentId = @Id;

            EXEC purchase.usp_GoodsReceipt_TrueUpCost @ReceiptLines, N'LCA', @Id, @Number, @UserId,
                 @AdjAmount OUTPUT, @AdjInventory OUTPUT, @AdjCogs OUTPUT, @AdjLines OUTPUT;

            -- Each receipt line's change is shared over the adjustment lines it is matched to, by matched pieces x what the
            -- adjustment adds per piece of each line (one invoice line per receipt line in practice); its in-stock pieces
            -- by matched pieces. The cents lost by rounding go to the line with the largest allocation.
            DECLARE @Share TABLE (PurchaseLineId INT NOT NULL PRIMARY KEY, Matched INT NOT NULL, InStock DECIMAL(18,6) NOT NULL,
                                  Inv DECIMAL(18,2) NOT NULL, Cogs DECIMAL(18,2) NOT NULL);
            WITH w AS (SELECT x.PurchaseLineId, m.GoodsReceiptLineId, Qty = m.QuantityBase,
                              Wt = CAST(m.QuantityBase AS DECIMAL(38,10)) * ABS(x.ExtraPerBaseUnit)
                       FROM purchase.LandedCostAdjustmentLines x
                       INNER JOIN purchase.GoodsReceiptInvoiceMatches m ON m.InvoiceLineId = x.PurchaseLineId
                       WHERE x.AdjustmentId = @Id),
                 t AS (SELECT GoodsReceiptLineId, WSum = SUM(Wt), QSum = SUM(Qty) FROM w GROUP BY GoodsReceiptLineId),
                 c AS (SELECT GoodsReceiptLineId, InStock = SUM(InStockBase), Inv = SUM(InventoryBase), Cogs = SUM(CogsBase)
                       FROM purchase.GoodsReceiptCostChanges
                       WHERE CauseKind = N'LCA' AND CauseId = @Id
                       GROUP BY GoodsReceiptLineId)
            INSERT INTO @Share (PurchaseLineId, Matched, InStock, Inv, Cogs)
            SELECT w.PurchaseLineId, SUM(w.Qty),
                   ISNULL(SUM(c.InStock * w.Qty / t.QSum), 0),
                   ROUND(ISNULL(SUM(c.Inv * f.F), 0), 2),
                   ROUND(ISNULL(SUM(c.Cogs * f.F), 0), 2)
            FROM w
            INNER JOIN t ON t.GoodsReceiptLineId = w.GoodsReceiptLineId
            LEFT  JOIN c ON c.GoodsReceiptLineId = w.GoodsReceiptLineId
            CROSS APPLY (SELECT F = CASE WHEN t.WSum > 0 THEN w.Wt / t.WSum ELSE CAST(w.Qty AS DECIMAL(38,10)) / t.QSum END) f
            GROUP BY w.PurchaseLineId;

            UPDATE x
            SET ReceivedBase         = ISNULL(s.Matched, 0),
                NetReceivedBase      = ISNULL(s.Matched, 0) - CASE WHEN l.ReturnedQuantityBase < ISNULL(s.Matched, 0) THEN l.ReturnedQuantityBase ELSE ISNULL(s.Matched, 0) END,
                RemainingBase        = CAST(ROUND(ISNULL(s.InStock, 0), 0) AS INT),
                InventoryPortionBase = ISNULL(s.Inv, 0),
                CogsPortionBase      = ISNULL(s.Cogs, 0)
            FROM purchase.LandedCostAdjustmentLines x
            INNER JOIN purchase.PurchaseDocumentLines l ON l.Id = x.PurchaseLineId
            LEFT  JOIN @Share s ON s.PurchaseLineId = x.PurchaseLineId
            WHERE x.AdjustmentId = @Id;

            WITH d AS (SELECT x.Id,
                              InvDiff  = @AdjInventory - SUM(x.InventoryPortionBase) OVER (),
                              CogsDiff = @AdjCogs - SUM(x.CogsPortionBase) OVER (),
                              Rn = ROW_NUMBER() OVER (ORDER BY ABS(x.AllocatedBase) DESC, x.Id)
                       FROM purchase.LandedCostAdjustmentLines x
                       WHERE x.AdjustmentId = @Id)
            UPDATE x
            SET InventoryPortionBase = x.InventoryPortionBase + d.InvDiff, CogsPortionBase = x.CogsPortionBase + d.CogsDiff
            FROM purchase.LandedCostAdjustmentLines x INNER JOIN d ON d.Id = x.Id
            WHERE d.Rn = 1 AND (d.InvDiff <> 0 OR d.CogsDiff <> 0);
        END

        UPDATE a
        SET Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId,
            InventoryPortionBase = ISNULL(t.Inv, 0), CogsPortionBase = ISNULL(t.Cogs, 0)
        FROM purchase.LandedCostAdjustments a
        CROSS APPLY (SELECT SUM(InventoryPortionBase) AS Inv, SUM(CogsPortionBase) AS Cogs FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id) t
        WHERE a.Id = @Id;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@InvoiceId, N'Updated', LEFT(N'Landed cost adjustment ' + @Number + N' posted: ' + CAST((SELECT TotalChargesBase FROM purchase.LandedCostAdjustments WHERE Id = @Id) AS NVARCHAR(30)) + N' added to the landed cost'
                                             -- (65) what it did to the goods already received
                                             + CASE WHEN @UsesGoodsReceipts = 1 AND @AdjAmount <> 0
                                                    THEN N'; cost of received goods adjusted by ' + CAST(@AdjAmount AS NVARCHAR(30)) + N' (stock '
                                                         + CAST(@AdjInventory AS NVARCHAR(30)) + N', cost of sales ' + CAST(@AdjCogs AS NVARCHAR(30)) + N')'
                                                    ELSE N'' END, 500), @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (65) from the body of script 23. On an invoice that uses goods receipts (UsesGoodsReceipts = 1), the
-- invoice lines get their landed cost back FIRST (as before), then the goods received against them are brought to
-- that cost (usp_GoodsReceipt_TrueUpCost, cause LCACANCEL: compensating GRNCOST rows, the average and last cost
-- replayed). Its posting wrote no LCA rows, so there are none to reverse. Invoices posted before the switch keep the
-- current logic unchanged. The matching lock first (usp_GoodsReceipt_LockMatching), whatever the invoice: the item
-- costs are replayed from the goods receipts, which a posting may be writing.
CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 67000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        -- (65) lock order: the goods receipt matcher first, then rows
        EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @Status TINYINT, @InvoiceId INT, @Number NVARCHAR(30), @BranchId INT;
        SELECT @Status = Status, @InvoiceId = SourceInvoiceId, @Number = DocumentNumber, @BranchId = BranchId
        FROM purchase.LandedCostAdjustments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
        IF @Status <> 2 THROW 67010, 'Only posted adjustments can be cancelled.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 67004, 'This adjustment was modified by another user. Reload the page and try again.', 1;

        -- (65) an invoice whose goods come with goods receipts: the cost moves back through the receipts
        DECLARE @UsesGoodsReceipts BIT =
            ISNULL((SELECT CAST(CASE WHEN dt.Code = N'PINV' AND d.UsesGoodsReceipts = 1 THEN 1 ELSE 0 END AS BIT)
                    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                    WHERE d.Id = @InvoiceId), 0);

        -- Reverse the value ledger and the invoice landed cost. (65) An invoice that uses goods receipts has no LCA rows.
        INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
        SELECT SYSUTCDATETIME(), c.ItemId, c.WarehouseId, c.BranchId, c.Kind, -c.AmountBase, c.SourceKind, c.SourceId, c.SourceNumber, c.PurchaseLineId, @UserId
        FROM inventory.CostAdjustments c WHERE c.SourceKind = N'LCA' AND c.SourceId = @Id AND c.AmountBase > 0;

        UPDATE l SET AllocatedChargesBase = l.AllocatedChargesBase - x.AllocatedBase, UnitCostBase = x.LandedCostBefore
        FROM purchase.PurchaseDocumentLines l INNER JOIN purchase.LandedCostAdjustmentLines x ON x.PurchaseLineId = l.Id
        WHERE x.AdjustmentId = @Id;
        UPDATE d SET TotalChargesBase = ISNULL(x.Charges, 0), TotalLandedCostBase = d.TotalAmountBase + ISNULL(x.Charges, 0)
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT SUM(AllocatedChargesBase) AS Charges FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId) x
        WHERE d.Id = @InvoiceId;

        -- (65) AN INVOICE THAT USES GOODS RECEIPTS: the goods received against the adjusted lines go back to the cost the
        --      invoice lines carry again.
        DECLARE @AdjAmount DECIMAL(18,2) = 0, @AdjInventory DECIMAL(18,2) = 0, @AdjCogs DECIMAL(18,2) = 0, @AdjLines INT = 0;
        IF @UsesGoodsReceipts = 1
        BEGIN
            DECLARE @ReceiptLines logistics.tvp_IdList;
            INSERT INTO @ReceiptLines (Id)
            SELECT DISTINCT m.GoodsReceiptLineId
            FROM purchase.GoodsReceiptInvoiceMatches m
            INNER JOIN purchase.LandedCostAdjustmentLines x ON x.PurchaseLineId = m.InvoiceLineId AND x.AdjustmentId = @Id;

            EXEC purchase.usp_GoodsReceipt_TrueUpCost @ReceiptLines, N'LCACANCEL', @Id, @Number, @UserId,
                 @AdjAmount OUTPUT, @AdjInventory OUTPUT, @AdjCogs OUTPUT, @AdjLines OUTPUT;
        END

        UPDATE purchase.LandedCostAdjustments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@InvoiceId, N'Updated', LEFT(N'Landed cost adjustment ' + @Number + N' cancelled: ' + @Reason
                                             -- (65) what it did to the goods already received
                                             + CASE WHEN @UsesGoodsReceipts = 1 AND @AdjAmount <> 0
                                                    THEN N'; cost of received goods adjusted by ' + CAST(@AdjAmount AS NVARCHAR(30)) + N' (stock '
                                                         + CAST(@AdjInventory AS NVARCHAR(30)) + N', cost of sales ' + CAST(@AdjCogs AS NVARCHAR(30)) + N')'
                                                    ELSE N'' END, 500), @UserId);

        -- Average / last cost recomputed from the ledger (the reversal rows net the adjustment out).
        DECLARE @ItemId INT;
        DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id;
        OPEN items; FETCH NEXT FROM items INTO @ItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC inventory.usp_Item_RebuildCosts @ItemId;
            FETCH NEXT FROM items INTO @ItemId;
        END
        CLOSE items; DEALLOCATE items;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 24. Container charges: the container's status read under lock */

-- Re-created (65) from the body of script 27. A charge posted while its container is being received: goods receipt Post
-- holds the container (UPDLOCK) and re-spreads and freezes the posted charges, then sets the container Offloaded; an
-- update lock does not stop a plain read, so this procedure read "Cleared" and posted the charge as one before the
-- receipt - after the receipt had frozen the others - leaving it neither frozen in the goods' cost nor adjusted after
-- (no CNTCHARGE rows): it entered no cost at all. Now the containers of the charges are read WITH (UPDLOCK, HOLDLOCK),
-- all of them first and in Id order (two postings never cross, and no charge is written before every container is
-- held): during a receipt this posting waits, then sees Offloaded and posts a late charge (usp_ContainerCharge_ApplyCost);
-- the other way round the receipt waits and freezes the posted charge itself. Nothing else changes.
-- Posts one draft (@Id) or several (@Ids, e.g. a whole group) in one transaction.
-- Before the offload: the charge joins the provisional cost of the lines. After the offload: cost adjustment
-- (the part still in stock -> average cost, the part already sold -> COGS).
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_Post
    @Id         INT       = NULL,
    @Ids        logistics.tvp_IdList READONLY,
    @RowVersion BINARY(8) = NULL,     -- checked with @Id only
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @List TABLE (Id INT PRIMARY KEY);
    INSERT INTO @List (Id) SELECT Id FROM @Ids;
    IF @Id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @List WHERE Id = @Id) INSERT INTO @List (Id) VALUES (@Id);
    IF NOT EXISTS (SELECT 1 FROM @List) THROW 70000, 'Select at least one charge.', 1;
    IF @Id IS NOT NULL AND @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 70004, 'This charge was modified by another user. Reload the page and try again.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = CASE WHEN ch.Id IS NULL THEN N'A selected charge no longer exists.'
                               WHEN ch.Status <> 1 THEN N'A charge of container ' + c.ContainerRef + N' is not a draft.'
                               ELSE N'Container ' + c.ContainerRef + N' is closed or cancelled.' END
    FROM @List x
    LEFT JOIN logistics.ContainerCharges ch ON ch.Id = x.Id
    LEFT JOIN logistics.Containers c        ON c.Id = ch.ContainerId
    WHERE ch.Id IS NULL OR ch.Status <> 1 OR c.Status IN (7, 8);
    IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- (65) the containers of the charges, held until the commit, before anything is written (see above)
        DECLARE @HeldContainers INT = (SELECT COUNT(*) FROM logistics.Containers c WITH (UPDLOCK, HOLDLOCK)
                                       WHERE c.Id IN (SELECT ch.ContainerId FROM @List x INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id));

        DECLARE @ChargeId INT, @ContainerId INT, @CtStatus TINYINT, @Method NVARCHAR(10), @InLanded BIT,
                @AmountBase DECIMAL(18,2), @Ref NVARCHAR(30), @Label NVARCHAR(200), @After BIT;
        DECLARE posts CURSOR LOCAL FAST_FORWARD FOR
            SELECT ch.Id FROM @List x INNER JOIN logistics.ContainerCharges ch ON ch.Id = x.Id ORDER BY ch.ContainerId, ch.Id;
        OPEN posts;
        FETCH NEXT FROM posts INTO @ChargeId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- (65) the container's status as committed: a goods receipt of it has finished (or not begun)
            SELECT @ContainerId = ch.ContainerId, @CtStatus = c.Status, @Method = ch.AllocationMethod, @InLanded = ch.IncludeInLandedCost,
                   @AmountBase = ch.AmountBase, @Ref = c.ContainerRef,
                   @Label = t.ChargeCode + N' ' + t.ChargeName + N' ' + CAST(ch.Amount AS NVARCHAR(30)) + N' ' + cur.CurrencyCode
            FROM logistics.ContainerCharges ch
            INNER JOIN logistics.Containers c WITH (UPDLOCK, HOLDLOCK) ON c.Id = ch.ContainerId
            INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
            INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
            WHERE ch.Id = @ChargeId;

            SET @After = CASE WHEN @CtStatus = 6 AND @InLanded = 1 THEN 1 ELSE 0 END;

            IF @InLanded = 1 AND @Method <> N'Manual'
                EXEC logistics.usp_ContainerCharge_Allocate @ChargeId, 0;
            IF @InLanded = 1 AND @Method = N'Manual'
               AND ABS(ISNULL((SELECT SUM(AmountBase) FROM logistics.ContainerChargeAllocations WHERE ChargeId = @ChargeId), 0) - @AmountBase) > 0.01
            BEGIN
                SET @Msg = N'Container ' + @Ref + N': the manual shares of ' + @Label + N' must add up to '
                         + CAST(@AmountBase AS NVARCHAR(30)) + N' (base currency). Edit the charge first.';
                THROW 70013, @Msg, 1;
            END

            UPDATE logistics.ContainerCharges
            SET Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId, AdjustedAfterOffload = @After,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @ChargeId;

            EXEC logistics.usp_Container_RecalcCosts @ContainerId;
            IF @After = 1 EXEC logistics.usp_ContainerCharge_ApplyCost @ChargeId, 1, @UserId;

            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@ContainerId, N'Updated', LEFT(N'Charge posted: ' + @Label
                                                   + CASE WHEN @After = 1 THEN N' (after the offload: item costs adjusted)' ELSE N'' END, 500), @UserId);

            FETCH NEXT FROM posts INTO @ChargeId;
        END
        CLOSE posts;
        DEALLOCATE posts;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Re-created (65) from the body of script 47. The same race on cancel: the charge and its container were read before
-- the transaction, without a lock, so a cancel decided "not in the goods' cost" while a goods receipt was freezing the
-- charge (AppliedAtOffload) - the cost stayed in the received goods with the charge cancelled. Now, inside the
-- transaction, the container is read WITH (UPDLOCK, HOLDLOCK) first (the order goods receipt Post and Cancel lock in),
-- then the charge: the cancel waits for a receipt in progress and decides on what it committed. The refusals are
-- unchanged (same numbers and words), only made inside the transaction.
-- Cancels a POSTED charge. When it is already in the cost of offloaded goods, the cost is reversed the same way.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 70000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- (65) under lock: the container first, then the charge (a charge never changes container)
        DECLARE @ContainerId INT = (SELECT ContainerId FROM logistics.ContainerCharges WHERE Id = @Id);
        DECLARE @Status TINYINT, @CtStatus TINYINT, @InCost BIT, @Label NVARCHAR(200);
        SELECT @CtStatus = c.Status FROM logistics.Containers c WITH (UPDLOCK, HOLDLOCK) WHERE c.Id = @ContainerId;
        SELECT @Status = ch.Status,
               @InCost = CASE WHEN @CtStatus = 6 AND ch.IncludeInLandedCost = 1 AND (ch.AppliedAtOffload = 1 OR ch.AdjustedAfterOffload = 1) THEN 1 ELSE 0 END,
               @Label = t.ChargeCode + N' ' + t.ChargeName + N' ' + CAST(ch.Amount AS NVARCHAR(30)) + N' ' + cur.CurrencyCode
        FROM logistics.ContainerCharges ch WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
        INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
        WHERE ch.Id = @Id AND ch.ContainerId = @ContainerId;

        IF @Status IS NULL THROW 70006, 'Charge not found.', 1;
        IF @Status <> 2 THROW 70010, 'Only a posted charge can be cancelled (delete a draft instead).', 1;
        -- (47) Money paid against it would be left pointing at nothing: the payments are reversed (or de-allocated) first.
        IF EXISTS (SELECT 1 FROM purchase.PaymentAllocations a INNER JOIN purchase.Payments p ON p.Id = a.PaymentId
                   WHERE a.ContainerChargeId = @Id AND a.RemovedAtUtc IS NULL AND p.Status = 2)
            THROW 70010, 'This charge cannot be cancelled: supplier payments are allocated to it. Reverse those payments (or remove the allocations) first.', 1;
        IF @CtStatus = 7 THROW 70010, 'The container is closed. Reopen it first.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 70004, 'This charge was modified by another user. Reload the page and try again.', 1;

        UPDATE logistics.ContainerCharges
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        EXEC logistics.usp_Container_RecalcCosts @ContainerId;
        IF @InCost = 1 EXEC logistics.usp_ContainerCharge_ApplyCost @Id, -1, @UserId;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@ContainerId, N'Updated', LEFT(N'Charge cancelled: ' + @Label + N' - ' + @Reason
                                               + CASE WHEN @InCost = 1 THEN N' (item costs adjusted back)' ELSE N'' END, 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 99. Check */

-- REPORT ONLY: nothing here changes data. The API discards PRINT and SELECT output at start-up; these lists are for
-- sqlcmd runs (the in-app filters serve users: Containers "Delivered, not received", invoices "Not fully received",
-- orders "To receive").

SELECT o.ObjectName, ObjectType = ISNULL(so.type_desc, N'MISSING')
FROM (VALUES (N'purchase.usp_PurchaseDocument_ValidateInput'), (N'purchase.usp_PurchaseDocument_Save'),
             (N'purchase.usp_PurchaseDocument_Post'), (N'purchase.usp_PurchaseDocument_Cancel'),
             (N'purchase.usp_PurchaseDocument_CreateFromSource'), (N'purchase.usp_PurchaseDocument_CreateFromContainers'),
             (N'purchase.usp_PurchaseDocument_Get'), (N'purchase.usp_PurchaseDocument_Search'),
             (N'purchase.usp_PurchaseDocument_Close'),
             (N'purchase.usp_PurchaseInvoice_LinkContainers'), (N'purchase.usp_PurchaseInvoice_UnlinkContainer'),
             (N'purchase.usp_PurchaseInvoice_LinkCandidates'), (N'purchase.fn_PurchaseInvoice_ContainerState'),
             (N'purchase.usp_LandedCostAdjustment_Save'),
             (N'purchase.usp_LandedCostAdjustment_Post'), (N'purchase.usp_LandedCostAdjustment_Cancel'),
             (N'logistics.usp_ContainerCharge_Post'), (N'logistics.usp_ContainerCharge_Cancel'),
             (N'logistics.usp_Movement_SetStatus'), (N'logistics.usp_Movement_Get'),
             (N'logistics.usp_Container_Offload'), (N'logistics.usp_Container_CancelOffload'),
             (N'logistics.usp_Container_Close'), (N'logistics.usp_Container_Reopen'), (N'logistics.fn_Container_CloseBlock'),
             (N'logistics.usp_Container_Save'), (N'logistics.usp_Container_Cancel'), (N'logistics.usp_Container_Delete'),
             (N'logistics.usp_Container_PlanFromOrder'), (N'logistics.usp_Container_CreateBatch'),
             (N'logistics.usp_Container_AvailablePoLines'), (N'logistics.usp_Container_InvoiceCandidates'),
             (N'logistics.usp_Container_Get'), (N'logistics.usp_Container_Search'), (N'logistics.usp_Container_Tracking'),
             (N'inventory.usp_Item_RebuildCosts'), (N'inventory.usp_Item_StockStatement'),
             (N'inventory.fn_Shortage_Live'), (N'inventory.usp_Item_PurchaseOrders')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(o.ObjectName)
ORDER BY ObjectType, o.ObjectName;                                    -- expected 39: 3 functions, 36 procedures, none MISSING

-- The switch: one row, written once.
SELECT SwitchedAtUtc FROM purchase.GoodsReceiptSwitch;               -- expected 1 row

-- DRIFT: order lines whose received / settled-short counters differ from what the documents say - the formula of the
-- switch, which every event since keeps true: (a) the non-reversed stock rows of old local invoices, (b) containers
-- offloaded the old way (received; loaded - received), (c) posted goods receipt lines (received; settled short).
-- Expected: none. Never corrected here: an administrator decides.
WITH inv AS
(
    SELECT PoLineId = il.SourceLineId, Qty = SUM(m.QuantityBase)
    FROM inventory.StockMovements m
    INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = m.DocumentLineId AND il.DocumentId = m.DocumentId
    WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'PINV' AND m.IsReversal = 0
      AND il.SourceLineId IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM inventory.StockMovements r
                      WHERE r.DocumentFamily = m.DocumentFamily AND r.DocumentTypeCode = m.DocumentTypeCode
                        AND r.DocumentId = m.DocumentId AND r.IsReversal = 1)
    GROUP BY il.SourceLineId
),
olo AS
(
    SELECT cl.PoLineId, Qty = SUM(ISNULL(cl.ReceivedQuantityBase, 0)),
           Short = SUM(CASE WHEN cl.ReceivedQuantityBase IS NOT NULL AND cl.QuantityBase > cl.ReceivedQuantityBase
                            THEN cl.QuantityBase - cl.ReceivedQuantityBase ELSE 0 END)
    FROM logistics.ContainerLines cl
    CROSS APPLY logistics.fn_Container_ReceivedBy(cl.ContainerId) rb
    WHERE cl.PoLineId IS NOT NULL AND rb.ReceivedBy = N'Offload'
    GROUP BY cl.PoLineId
),
grn AS
(
    SELECT gl.PoLineId, Qty = SUM(gl.QuantityBase), Short = SUM(gl.SettledShortBase)
    FROM purchase.GoodsReceiptLines gl
    INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId AND g.Status = 2
    WHERE gl.PoLineId IS NOT NULL
    GROUP BY gl.PoLineId
)
SELECT Drift = N'DRIFT', d.Id AS OrderId, d.DocumentNumber, pol.LineNumber, i.ItemCode,
       pol.GoodsReceivedBase, ExpectedReceivedBase = x.Qty, pol.GoodsShortBase, ExpectedShortBase = x.Short
FROM purchase.PurchaseDocumentLines pol
INNER JOIN purchase.PurchaseDocuments d ON d.Id = pol.DocumentId
INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
INNER JOIN inventory.Items i            ON i.Id = pol.ItemId
LEFT  JOIN inv ON inv.PoLineId = pol.Id
LEFT  JOIN olo ON olo.PoLineId = pol.Id
LEFT  JOIN grn ON grn.PoLineId = pol.Id
CROSS APPLY (SELECT Qty   = ISNULL(inv.Qty, 0) + ISNULL(olo.Qty, 0) + ISNULL(grn.Qty, 0),
                    Short = ISNULL(olo.Short, 0) + ISNULL(grn.Short, 0)) x
WHERE pol.GoodsReceivedBase <> x.Qty OR pol.GoodsShortBase <> x.Short
ORDER BY d.Id, pol.LineNumber;                                        -- expected none

-- Containers delivered but not received (confirmed to cleared, their latest Delivery completed, no goods receipt):
-- they need "Receive goods..." on the container (a Delivery completed before the switch made no draft).
SELECT c.ContainerRef, c.ContainerNo, c.Status, ld.MovementNo, ld.EndDate, Place = ld.PlaceName
FROM logistics.Containers c
CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
CROSS APPLY logistics.fn_Container_LastDelivery(c.Id) ld
WHERE c.Status BETWEEN 2 AND 5 AND rb.GoodsReceiptId IS NULL
ORDER BY ld.EndDate, c.ContainerRef;

-- Lines of posted "Shipped in containers" invoices not linked to a container and not fully received: matched to their
-- container's goods when it is received (same order line), else received with "Receive goods..." on the invoice.
SELECT d.DocumentNumber, l.LineNumber, i.ItemCode, InvoicedBase = l.QuantityBase, ReceivedBase = l.ReceivedQuantityBase
FROM purchase.PurchaseDocumentLines l
INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
INNER JOIN inventory.Items i            ON i.Id = l.ItemId
WHERE d.Status IN (2, 4) AND d.ReceiptMode = 2 AND l.ContainerLineId IS NULL AND l.ReceivedQuantityBase < l.QuantityBase
ORDER BY d.DocumentNumber, l.LineNumber;

-- Orders closed "Fully received" (fully invoiced, before goods receipts) with goods still to come: they stay closed and
-- can still be received.
SELECT d.DocumentNumber, d.ClosedAtUtc, OutstandingBase = SUM(p.OutstandingBase)
FROM purchase.PurchaseDocuments d
INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
CROSS APPLY purchase.fn_PoLine_Progress(d.Id) p
WHERE d.Status = 4 AND d.CloseReason = N'Fully received'
GROUP BY d.Id, d.DocumentNumber, d.ClosedAtUtc
HAVING SUM(p.OutstandingBase) > 0
ORDER BY d.DocumentNumber;

-- Posted landed cost adjustments on "Shipped in containers" invoices (ReceiptMode 2), from before 67012 refused them:
-- they raised the invoice lines' charges, which goods received outside containers would count again at the invoice's
-- landed cost. Expected: none. An administrator decides (cancel the adjustment, enter the charge on the containers).
SELECT a.DocumentNumber, Invoice = d.DocumentNumber, a.PostedAtUtc, a.TotalChargesBase, d.UsesGoodsReceipts
FROM purchase.LandedCostAdjustments a
INNER JOIN purchase.PurchaseDocuments d ON d.Id = a.SourceInvoiceId
WHERE a.Status = 2 AND d.ReceiptMode = 2
ORDER BY a.PostedAtUtc;

-- Containers offloaded the old way that Cancel Offload can still reverse (Offloaded, not closed).
SELECT c.ContainerRef, c.OffloadedDate
FROM logistics.Containers c
CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
WHERE rb.ReceivedBy = N'Offload' AND c.Status = 6
ORDER BY c.ContainerRef;

PRINT 'Script 65 applied: goods receipts switched on - supplier invoices move no stock, containers and local purchases are received with goods receipts, invoice and receipt costs follow each other.';
GO

SET NOEXEC OFF;
GO
