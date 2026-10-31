SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 89: FIXES - LATE CHARGES ON COMPANY STOCK, CANCELS REPLAY COSTS, A PARENT PLAN'S PURCHASE
   ORDER, DOCUMENT TYPE SETTINGS KEPT

   Ships first, before the inventory transfers (scripts 90-94), and is independent of them.

     1. LATE CONTAINER CHARGES AND OLD LANDED COST ADJUSTMENTS SPLIT ON THE COMPANY'S STOCK. A charge posted (or
        cancelled) after the container's goods are received, and an LCA of an invoice posted before goods receipts,
        divided their amount between stock and cost of sales on the stock of the RECEIVING warehouse, although the
        average is company-wide and every warehouse is valued at it. Goods moved to another warehouse sent their share
        to cost of sales: KTG-2026-0031 brought 84 pcs into LUB-01, 80 moved to LKS-01, a late charge of 2,940 USD put
        140.00 in stock and 2,800.00 in cost of sales although the company still held all 84. They now split on the
        company's stock of the item (every warehouse), as the goods receipt true-up (GRNCOST) does; a cancel never
        takes more out of stock than its posting put in. The old LCA also counted one warehouse's stock twice for two
        lines of one item there: its pieces still held are worked out per item, and the lines' rounded Remaining add
        up to the item's.
     2. CANCELLING A STOCK DOCUMENT REVERSES ONLY ITS OWN ROWS: family Inventory, its type code and its id (it reversed
        every Inventory row with the document's id, whatever their type). A document with none is refused (62010)
        instead of being marked cancelled with its stock still there.
     3. EVERY CANCEL REPLAYS ITS ITEMS' COSTS. No cancel replayed the average except a sales return's: an Inventory
        In's posting moved the average and its cancel left it there (10 at 100, In 10 at 200 -> 150; cancelled: still
        150, the replay says 100); an Out's or a sale's reversal gives the stock back at the cost frozen at its posting
        while the average may have moved since. Every stock-document cancel (Inventory In, Inventory Out, BIVAC Out)
        and every sales cancel now replays its items, under the goods receipt matching lock (the replay reads the
        goods receipts). The items of the documents cancelled before this script are replayed ONCE, recorded in the
        new table inventory.OneTimeSteps (a long replay continues at the next start). A cancel GIVES WAY IN A DEADLOCK
        (DEADLOCK_PRIORITY LOW): it now reads the item's ledger and updates the item, so it can meet an Inventory In,
        a sale or a container charge posting the same item; it is then the one rolled back, and the API runs it again
        (a posting has no retry). Script 19's per-start backfill of item costs no longer counts a posting that was
        reversed (edited where it stands, like the seeds of point 5): it gave an item whose every receipt was
        cancelled - replayed to a zero average and no last cost - the cancelled document's cost back as its average
        AND its last cost at the next start.
     4. A SHORTAGE PLAN FOR A PARENT WAREHOUSE CREATES ITS PURCHASE ORDER AGAIN. Since script 70 a purchase line takes
        a warehouse at the bottom of the tree (65000), and the plan's warehouse - a parent, which script 62 allows -
        went on every line. Each line now takes the item's default warehouse when it is an active warehouse at the
        bottom of the plan's tree, else the first of those (the plan's branch first, then by code); a tree with none
        is refused (66000). The creation is one transaction.
     5. DOCUMENT TYPE SETTINGS ARE KEPT. Five older seed batches reset DefaultPricing, PriceEditable, NumberPerBranch
        (and YearInNumber / NumberLength) of twelve types at EVERY start, undoing what an administrator saves in
        Configuration › Document Types: scripts 19 (INV_IN, INV_OUT, PO, PINV, PRET, SO, SINV, SRET), 22 (SHR), 23
        (LCA), 24 (CNT) and 27 (MOV). They now touch only a type nobody has saved (UpdatedAtUtc IS NULL), as the later
        seeds already do (RCPT, PAY, GRN). This is the one exception to "never edit an older script": a reset that
        re-runs at every start runs before any later script and cannot be undone by one. Those five batches (and the
        backfill of point 3) are edited where they stand (their Database/NN_*.sql file and their copy in Schema.sql).
     6. The documentation lines that were out of date are corrected (business-context, costing-rules).

   Objects:
     inventory.OneTimeSteps                              NEW table: a data step that must run once per database
     logistics.usp_ContainerCharge_ApplyCost             re-created from the body of script 27 (1)
     purchase.usp_LandedCostAdjustment_Post              re-created from the body of script 79 (1)
     inventory.usp_StockDocument_Cancel                  re-created from the body of script 15 (2, 3)
     sales.usp_SalesDocument_Cancel                      re-created from the body of script 84 (3)
     inventory.usp_ShortageDocument_CreatePurchaseOrder  re-created from the body of script 22 (4)

   Not changed: every validation, message, number and result set of those procedures (but the new 62010 of a stock
   document without rows of its own, and 66000 for a plan whose tree has no active warehouse at the bottom); GRNCOST,
   NEGSTOCK, inventory.usp_Item_RebuildCosts; existing cost adjustments, LCA lines and stock rows are never rewritten.
   No new permission or error number.

   Requires scripts 15, 22, 23, 27, 28 (warehouse hierarchy), 64, 65, 70, 79 and 84 (Schema.sql runs them first).
   Idempotent, additive: re-applied at every API start-up, and builds a brand-new empty database.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'inventory.StockDocuments', N'U') IS NULL                                -- 15
   OR OBJECT_ID(N'inventory.ShortageDocuments', N'U') IS NULL                          -- 22
   OR OBJECT_ID(N'purchase.LandedCostAdjustmentLines', N'U') IS NULL                   -- 23
   OR COL_LENGTH(N'logistics.ContainerCharges', N'AdjustedAfterOffload') IS NULL       -- 27
   OR OBJECT_ID(N'masterdata.fn_Warehouse_Subtree') IS NULL                            -- 28 (warehouse hierarchy)
   OR OBJECT_ID(N'purchase.usp_GoodsReceipt_LockMatching', N'P') IS NULL               -- 64
   OR OBJECT_ID(N'purchase.usp_GoodsReceipt_TrueUpCost', N'P') IS NULL                 -- 64
   OR COL_LENGTH(N'purchase.PurchaseDocuments', N'UsesGoodsReceipts') IS NULL          -- 65
   OR OBJECT_ID(N'masterdata.fn_Warehouse_IsLeaf') IS NULL                             -- 70
   OR COL_LENGTH(N'purchase.PurchaseDocuments', N'AffectsCost') IS NULL                -- 79
   OR COL_LENGTH(N'sales.SalesDocuments', N'CancelDate') IS NULL                       -- 84
    THROW 62000, 'Script 89 requires scripts 15, 22, 23, 27, 28 (warehouse hierarchy), 64, 65, 70, 79 and 84: apply them first.', 1;
GO

/* ================================================================== 1. inventory.OneTimeSteps */

-- (89) A DATA STEP THAT MUST RUN ONCE PER DATABASE RECORDS ITSELF HERE. Schema.sql re-runs every batch at every start
--      and re-creates the older bodies of a procedure first, so a procedure body can never say "already done".
--      Progress lets a long step run in parts across starts (each start has 300 s per batch).
IF OBJECT_ID(N'inventory.OneTimeSteps', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.OneTimeSteps
    (
        StepCode     NVARCHAR(60)  NOT NULL CONSTRAINT PK_OneTimeSteps PRIMARY KEY CLUSTERED,
        StartedAtUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_OneTimeSteps_Started DEFAULT (SYSUTCDATETIME()),
        DoneAtUtc    DATETIME2(3)  NULL,
        Progress     INT           NULL,
        Details      NVARCHAR(400) NULL
    );
    PRINT 'Created inventory.OneTimeSteps';
END
GO

/* ================================================================== 2. logistics.usp_ContainerCharge_ApplyCost */

-- A charge that enters (@Sign = 1) or leaves (@Sign = -1) the cost of goods already offloaded:
-- the part still in stock changes the inventory value (moving average), the part already sold goes to COGS.
-- Then the item costs are replayed (exact average, last / FOB cost from the latest receipt).
-- Re-created (89) from the body of script 27: THE PART STILL IN STOCK IS CAPPED BY THE COMPANY'S STOCK of the item, every
-- warehouse, as the goods receipt true-up (GRNCOST) does - no longer by the receiving warehouse's: the average is
-- company-wide, and goods moved to another warehouse (an Inventory Out + In, a transfer) are still held. A CANCEL OF A
-- CHARGE POSTED AFTER THE RECEIPT NEVER TAKES MORE OUT OF STOCK THAN ITS POSTING PUT IN, per item. The rows keep the
-- receiving warehouse and the container's branch, for the reports.
CREATE OR ALTER PROCEDURE logistics.usp_ContainerCharge_ApplyCost
    @ChargeId INT,
    @Sign     SMALLINT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ContainerId INT, @Ref NVARCHAR(30), @BranchId INT, @WarehouseId INT, @AdjustedAfter BIT;
    SELECT @ContainerId = c.Id, @Ref = c.ContainerRef, @BranchId = c.BranchId, @WarehouseId = c.WarehouseId,
           @AdjustedAfter = ch.AdjustedAfterOffload                                  -- (89) for the cancel's cap
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c ON c.Id = ch.ContainerId
    WHERE ch.Id = @ChargeId;
    IF @ContainerId IS NULL THROW 70006, 'Charge not found.', 1;
    IF @WarehouseId IS NULL THROW 70010, 'The container has no offloading warehouse.', 1;

    DECLARE @Adj TABLE (LineId INT PRIMARY KEY, ItemId INT, Delta DECIMAL(18,2), Inv DECIMAL(18,2) NULL);
    INSERT INTO @Adj (LineId, ItemId, Delta)
    SELECT cl.Id, cl.ItemId, @Sign * a.AmountBase
    FROM logistics.ContainerChargeAllocations a
    INNER JOIN logistics.ContainerLines cl ON cl.Id = a.ContainerLineId
    WHERE a.ChargeId = @ChargeId AND a.AmountBase <> 0;

    -- per item: what the container brought, and how much of it can still be in stock - (89) capped by the COMPANY's
    -- stock of the item, every warehouse (was: the receiving warehouse's stock)
    DECLARE @Items TABLE (ItemId INT PRIMARY KEY, Received DECIMAL(18,6), Remaining DECIMAL(18,6), CompanyOnHand DECIMAL(18,6));
    INSERT INTO @Items (ItemId, Received, Remaining, CompanyOnHand)
    SELECT x.ItemId, x.Received,
           CASE WHEN oh.Q < x.Received THEN CASE WHEN oh.Q > 0 THEN oh.Q ELSE 0 END ELSE x.Received END,
           oh.Q
    FROM (SELECT cl.ItemId, Received = SUM(ISNULL(cl.ReceivedQuantityBase, 0))
          FROM logistics.ContainerLines cl
          WHERE cl.ContainerId = @ContainerId
          GROUP BY cl.ItemId) x
    CROSS APPLY (SELECT Q = inventory.fn_StockOnHand(x.ItemId, NULL)) oh                -- (89) NULL: every warehouse
    WHERE x.ItemId IN (SELECT ItemId FROM @Adj);

    UPDATE a
    SET Inv = CASE WHEN i.CompanyOnHand <= 0 OR i.Received <= 0 THEN 0 ELSE ROUND(a.Delta * i.Remaining / i.Received, 2) END
    FROM @Adj a
    INNER JOIN @Items i ON i.ItemId = a.ItemId;

    -- (89) A CANCEL NEVER TAKES MORE OUT OF STOCK THAN ITS POSTING PUT IN, per item. The stock part above is worked out
    --      again with today's stock - right when goods were sold since the posting (they took their share of the charge
    --      to cost of sales at the average) - but it can exceed what the posting put in: a charge posted before script 89
    --      (the receiving warehouse's stock decided then), or pieces of other purchases received since (they count as the
    --      container's). Taking out more would push the average below where it was before the charge. It is lowered to
    --      the posting's Inventory rows, in proportion over the item's lines, the cents on the line with the largest
    --      amount; the rest goes to cost of sales. A charge frozen in the goods' cost at the receipt (AppliedAtOffload)
    --      put all of it in stock: no cap.
    IF @Sign = -1 AND @AdjustedAfter = 1
    BEGIN
        DECLARE @Cap TABLE (ItemId INT PRIMARY KEY, Posted DECIMAL(18,2) NOT NULL, TakenOut DECIMAL(18,2) NOT NULL);
        INSERT INTO @Cap (ItemId, Posted, TakenOut)
        SELECT a.ItemId,
               ISNULL((SELECT SUM(c.AmountBase) FROM inventory.CostAdjustments c
                       WHERE c.SourceKind = N'CNTCHARGE' AND c.SourceId = @ChargeId AND c.Kind = N'Inventory'
                         AND c.ItemId = a.ItemId), 0),
               -SUM(ISNULL(a.Inv, 0))
        FROM @Adj a
        GROUP BY a.ItemId;
        UPDATE @Cap SET Posted = 0 WHERE Posted < 0;

        UPDATE a
        SET Inv = -ROUND(-ISNULL(a.Inv, 0) * c.Posted / c.TakenOut, 2)
        FROM @Adj a
        INNER JOIN @Cap c ON c.ItemId = a.ItemId
        WHERE c.TakenOut > c.Posted;                                     -- TakenOut > Posted >= 0: never a division by 0

        ;WITH d AS (SELECT a.LineId, Diff = -c.Posted - SUM(ISNULL(a.Inv, 0)) OVER (PARTITION BY a.ItemId),
                           Rn = ROW_NUMBER() OVER (PARTITION BY a.ItemId ORDER BY ABS(a.Delta) DESC, a.LineId)
                    FROM @Adj a
                    INNER JOIN @Cap c ON c.ItemId = a.ItemId
                    WHERE c.TakenOut > c.Posted)
        UPDATE a SET Inv = ISNULL(a.Inv, 0) + d.Diff
        FROM @Adj a
        INNER JOIN d ON d.LineId = a.LineId
        WHERE d.Rn = 1 AND d.Diff <> 0;
    END

    INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
    SELECT SYSUTCDATETIME(), a.ItemId, @WarehouseId, @BranchId, k.Kind, k.Amount, N'CNTCHARGE', @ChargeId, @Ref, NULL, @UserId
    FROM @Adj a
    CROSS APPLY (VALUES (N'Inventory', ISNULL(a.Inv, 0)), (N'COGS', a.Delta - ISNULL(a.Inv, 0))) k (Kind, Amount)
    WHERE k.Amount <> 0;

    DECLARE @ItemId INT;
    DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM @Adj;
    OPEN items;
    FETCH NEXT FROM items INTO @ItemId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC inventory.usp_Item_RebuildCosts @ItemId;
        FETCH NEXT FROM items INTO @ItemId;
    END
    CLOSE items;
    DEALLOCATE items;
END
GO

/* ================================================================== 3. purchase.usp_LandedCostAdjustment_Post */

-- Re-created (89) from the body of script 79: on an invoice posted before goods receipts THE PART STILL IN STOCK IS
-- CAPPED BY THE COMPANY'S STOCK OF THE ITEM, per item over the adjusted lines (as the goods receipt true-up does), no
-- longer by each line's warehouse; the lines' rounded Remaining add up to the item's. An invoice that uses goods
-- receipts is unchanged (its true-up rewrites these figures).
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
        -- (79) an invoice that does not change item costs: an adjustment on it would change no cost
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId AND AffectsCost = 0)
            THROW 67013, 'This invoice does not change item costs (its document type was set so when it was posted): a landed cost adjustment on it would change no cost. Container charges still enter the cost of goods received in containers.', 1;

        -- (65) an invoice whose goods come with goods receipts: the cost moves through the receipts
        DECLARE @UsesGoodsReceipts BIT =
            ISNULL((SELECT CAST(CASE WHEN dt.Code = N'PINV' AND d.UsesGoodsReceipts = 1 THEN 1 ELSE 0 END AS BIT)
                    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                    WHERE d.Id = @InvoiceId), 0);

        EXEC purchase.usp_PurchaseCharges_Allocate N'LCA', @Id, @InvoiceId;

        DECLARE @Rate DECIMAL(18,6) = (SELECT ExchangeRate FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId);

        -- (89) WHAT IS STILL IN STOCK, PER ITEM, ON THE COMPANY'S STOCK (every warehouse), as the goods receipt true-up
        --      (GRNCOST) does: Remaining = min(net received of the item's adjusted lines, company on hand), shared over those
        --      lines by their net received. Was: each line capped by its own warehouse's stock, which sent to cost of sales
        --      the share of goods moved to another warehouse and counted a warehouse's stock twice for two lines of one
        --      item there. Only an invoice posted before goods receipts keeps these figures.
        DECLARE @Rem TABLE (ItemId INT NOT NULL PRIMARY KEY, NetReceived DECIMAL(18,6) NOT NULL, OnHand DECIMAL(18,6) NOT NULL,
                            Remaining DECIMAL(18,6) NOT NULL DEFAULT (0));
        INSERT INTO @Rem (ItemId, NetReceived, OnHand)
        SELECT l.ItemId,
               SUM(CASE WHEN l.QuantityBase - l.ReturnedQuantityBase > 0 THEN l.QuantityBase - l.ReturnedQuantityBase ELSE 0 END),
               inventory.fn_StockOnHand(l.ItemId, NULL)
        FROM purchase.PurchaseDocumentLines l
        CROSS APPLY (SELECT Allocated = ISNULL((SELECT SUM(x.AmountBase) FROM purchase.PurchaseChargeAllocations x
                                                 INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                                                 WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'LCA' AND c.DocumentId = @Id AND c.IncludeInLandedCost = 1), 0)) a
        WHERE l.DocumentId = @InvoiceId AND a.Allocated <> 0
        GROUP BY l.ItemId;

        UPDATE @Rem SET Remaining = CASE WHEN OnHand <= 0 OR NetReceived <= 0 THEN 0
                                         WHEN OnHand < NetReceived THEN OnHand ELSE NetReceived END;

        DELETE FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id;
        INSERT INTO purchase.LandedCostAdjustmentLines (AdjustmentId, PurchaseLineId, ItemId, WarehouseId, ReceivedBase, NetReceivedBase, RemainingBase,
                                                        AllocatedBase, ExtraPerBaseUnit, InventoryPortionBase, CogsPortionBase, LandedCostBefore, LandedCostAfter)
        SELECT @Id, l.Id, l.ItemId, l.WarehouseId, l.QuantityBase, n.NetReceived, CAST(ROUND(r.Remaining, 0) AS INT),   -- (89) re-rounded below
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
        INNER JOIN @Rem rm ON rm.ItemId = l.ItemId                                                                       -- (89)
        CROSS APPLY (SELECT Remaining = CAST(CASE WHEN rm.Remaining <= 0 OR rm.NetReceived <= 0 OR n.NetReceived <= 0 THEN 0
                                                  ELSE n.NetReceived * rm.Remaining / rm.NetReceived END AS DECIMAL(18,6))) r   -- (89)
        WHERE l.DocumentId = @InvoiceId AND a.Allocated <> 0;

        -- (89) THE LINES' ROUNDED "REMAINING" ADD UP TO THE ITEM'S ROUNDED PIECES STILL HELD (largest remainder): three
        --      lines sharing 10 pcs show 4 / 3 / 3, not 3 / 3 / 3. Display only: the portions above use the exact share.
        IF @UsesGoodsReceipts = 0
        BEGIN
            ;WITH s AS
            (
                SELECT a.Id, a.ItemId,
                       Share  = CASE WHEN rm.NetReceived > 0 AND a.NetReceivedBase > 0
                                     THEN CAST(a.NetReceivedBase AS DECIMAL(18,6)) * rm.Remaining / rm.NetReceived ELSE 0 END,
                       Target = CAST(ROUND(rm.Remaining, 0) AS INT)
                FROM purchase.LandedCostAdjustmentLines a
                INNER JOIN @Rem rm ON rm.ItemId = a.ItemId
                WHERE a.AdjustmentId = @Id
            ), r AS
            (
                SELECT s.Id, s.Target, Fl = CAST(FLOOR(s.Share) AS INT),
                       SumFl = SUM(CAST(FLOOR(s.Share) AS INT)) OVER (PARTITION BY s.ItemId),
                       Rk    = ROW_NUMBER() OVER (PARTITION BY s.ItemId ORDER BY s.Share - FLOOR(s.Share) DESC, s.Id)
                FROM s
            )
            UPDATE a SET RemainingBase = r.Fl + CASE WHEN r.Rk <= r.Target - r.SumFl THEN 1 ELSE 0 END
            FROM purchase.LandedCostAdjustmentLines a
            INNER JOIN r ON r.Id = a.Id;
        END

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

/* ================================================================== 4. inventory.usp_StockDocument_Cancel */

-- Re-created (89) from the body of script 15:
--   1. THE MATCHING LOCK FIRST (purchase.usp_GoodsReceipt_LockMatching), as the LCA cancel takes it: the cost replay
--      below reads the goods receipts, which a posting may be writing.
--   2. THE ROWS REVERSED ARE THE DOCUMENT'S OWN: family Inventory, ITS TYPE CODE and its id; a document with none is
--      refused instead of being marked cancelled with its stock still there.
--   3. EVERY CANCELLED STOCK DOCUMENT REPLAYS THE COST HISTORY OF ITS ITEMS: an In's posting moved the average, an Out's
--      reversal gives the stock back at the cost frozen when it was posted; the replay drops a reversed posting whole.
--   4. IT GIVES WAY IN A DEADLOCK: the replay reads the item's ledger and cost adjustments and updates the item, the
--      other way round from an Inventory In or a sale being posted (the item, then its ledger) or a late container
--      charge (its cost adjustments, then the ledger). The cancel is then the one rolled back, and the API runs it
--      again (SqlRetry.OnDeadlockAsync); those postings have no retry. Reverts when the procedure returns.
CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET DEADLOCK_PRIORITY LOW;                                                           -- (89) 4

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 62000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC purchase.usp_GoodsReceipt_LockMatching;                                     -- (89) 1

        DECLARE @Status TINYINT, @Direction SMALLINT, @Number NVARCHAR(30), @TypeCode NVARCHAR(20), @BranchId INT, @ReasonCode NVARCHAR(20);
        SELECT @Status = d.Status, @Direction = dt.StockDirection, @Number = d.DocumentNumber, @TypeCode = dt.Code, @BranchId = d.BranchId, @ReasonCode = r.ReasonCode
        FROM inventory.StockDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        LEFT  JOIN inventory.StockReasons r ON r.Id = d.ReasonId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 62006, 'Document not found.', 1;
        IF @Status <> 2 THROW 62010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This document was modified by another user. Reload the page and try again.', 1;

        -- Cancelling an incoming document removes stock again: it must still be there.
        IF @Direction = 1
        BEGIN
            DECLARE @Msg NVARCHAR(400);
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM inventory.StockDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 62007, @Msg, 1;
        END

        -- (89) 2. its own rows only; none is refused (a posted document has one row per line: inventory.usp_StockDocument_Post)
        IF NOT EXISTS (SELECT 1 FROM inventory.StockMovements m
                       WHERE m.DocumentFamily = N'Inventory' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @Id AND m.IsReversal = 0)
            THROW 62010, 'This document has no stock movements of its own to reverse. Ask the administrator to check the stock ledger.', 1;

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Inventory' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @Id AND m.IsReversal = 0;

        UPDATE inventory.StockDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        -- (89) 3. every cancelled stock document: replay the cost history of its items
        DECLARE @ItemId INT;
        DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM inventory.StockDocumentLines WHERE DocumentId = @Id;
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

/* ================================================================== 5. sales.usp_SalesDocument_Cancel */

-- Re-created (89) from the body of script 84: the matching lock first; EVERY cancelled sales document replays its items
-- (a sale's reversal gives the stock back at its frozen COGS cost while the average may have moved since; a return was
-- replayed already). It gives way in a deadlock (DEADLOCK_PRIORITY LOW, as the stock cancel): the replay can meet a
-- posting of the same item, which has no retry; the cancel is rolled back and the API runs it again.
CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @CancelDate DATE      = NULL,   -- script 84: the day it is cancelled (default today)
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET DEADLOCK_PRIORITY LOW;      -- (89) the cancel is the one rolled back in a deadlock, and the API runs it again

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 64000, 'A cancellation reason is required.', 1;

    /* THE CANCELLATION DATE (script 84): the day the reversal counts on, today unless typed. A day of
       tolerance as everywhere else (the date is the reader's local one, the check is UTC); never before
       the invoice it cancels. */
    IF @CancelDate IS NULL SET @CancelDate = CAST(SYSUTCDATETIME() AS DATE);
    IF @CancelDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 64000, 'The cancellation date cannot be in the future.', 1;
    DECLARE @InvoiceDate DATE = (SELECT DocumentDate FROM sales.SalesDocuments WHERE Id = @Id);
    IF @InvoiceDate IS NOT NULL AND @CancelDate < @InvoiceDate
    BEGIN
        DECLARE @DateMsg NVARCHAR(200) = N'The cancellation date cannot be before the document date ('
                                         + CONVERT(NVARCHAR(10), @InvoiceDate, 120) + N').';
        THROW 64000, @DateMsg, 1;
    END
    -- The reversal movements are dated on that day, at the time it is done (as a posting dates its own).
    DECLARE @ReversalAt DATETIME2(3) =
        DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@CancelDate AS DATETIME2(3)));

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC purchase.usp_GoodsReceipt_LockMatching;  -- (89) lock order: the matcher first, then rows (the replay reads the goods receipts)

        DECLARE @Status TINYINT, @Direction SMALLINT, @TypeCode NVARCHAR(20), @SourceId INT;
        SELECT @Status = d.Status, @Direction = dt.StockDirection, @TypeCode = dt.Code, @SourceId = d.SourceDocumentId
        FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 2 THROW 64010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE SourceDocumentId = @Id AND Status = 2)
            THROW 64010, 'This invoice cannot be cancelled: posted returns refer to it. Cancel those first.', 1;

        /* A CANCELLED INVOICE CANNOT KEEP MONEY APPLIED TO IT. Receipts allocated to it would be paying
           an invoice that no longer exists, and the customer's balance would quietly be wrong. The
           receipt has to be reversed (or its allocation removed) first, so somebody decides what
           happens to the money. Only receipts that are POSTED count: a draft allocates nothing yet. */
        /* THE AUTOMATIC RECEIPT OF A CASH INVOICE IS THE ONE EXCEPTION: it was made with the invoice,
           so it is undone with it - reversed here, in this transaction, with the reason. Money any
           OTHER receipt has put on the invoice is still somebody's decision and still blocks. */
        DECLARE @AutoReceiptId INT = (SELECT TOP (1) Id FROM sales.Receipts WHERE SourceSalesDocumentId = @Id AND Status = 2);
        IF EXISTS (SELECT 1 FROM sales.ReceiptAllocations a
                   INNER JOIN sales.Receipts r ON r.Id = a.ReceiptId
                   WHERE a.SalesDocumentId = @Id AND a.RemovedAtUtc IS NULL AND r.Status = 2
                     AND r.Id <> ISNULL(@AutoReceiptId, 0))
            THROW 64010, 'This invoice cannot be cancelled: receipts have been applied to it. Reverse those receipts first.', 1;

        IF @AutoReceiptId IS NOT NULL
        BEGIN
            DECLARE @RcReason NVARCHAR(500) = N'Invoice cancelled: ' + @Reason;
            EXEC sales.usp_Receipt_Reverse @Id = @AutoReceiptId, @Reason = @RcReason, @RowVersion = NULL, @UserId = @UserId, @FromInvoiceCancel = 1;
            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'ReceiptReversed', N'Cash sale: receipt ' + (SELECT ReceiptNumber FROM sales.Receipts WHERE Id = @AutoReceiptId) + N' reversed', @UserId);
        END

        IF @Direction = 1
        BEGIN
            DECLARE @Msg NVARCHAR(400);
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 64007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT @ReversalAt, m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Sales' AND m.DocumentId = @Id AND m.IsReversal = 0;

        IF @TypeCode = N'SRET' AND @SourceId IS NOT NULL
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase - x.Qty
            FROM sales.SalesDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

        UPDATE sales.SalesDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason, CancelDate = @CancelDate,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', N'On ' + CONVERT(NVARCHAR(10), @CancelDate, 120) + N': ' + @Reason, @UserId);

        -- (89) Every cancelled sales document: replay the cost history of its items.
        DECLARE @ItemId INT;
        DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM sales.SalesDocumentLines WHERE DocumentId = @Id;
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

/* ================================================================== 6. Once: the items of documents cancelled before 89 */

-- Their cancel left the average where the posting or the reversal had put it. Each item is replayed in its own short
-- transaction, under the matching lock, in ItemId order; Progress keeps the last item done, so a database with many
-- items finishes over several starts (the step stops after 200 s; each start has 300 s per batch). An empty
-- database marks the step done at once.
IF NOT EXISTS (SELECT 1 FROM inventory.OneTimeSteps WHERE StepCode = N'89.ReplayCancelledDocumentItems' AND DoneAtUtc IS NOT NULL)
BEGIN
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.OneTimeSteps WHERE StepCode = N'89.ReplayCancelledDocumentItems')
        INSERT INTO inventory.OneTimeSteps (StepCode, Progress) VALUES (N'89.ReplayCancelledDocumentItems', 0);

    DECLARE @Items TABLE (ItemId INT NOT NULL PRIMARY KEY);
    INSERT INTO @Items (ItemId)
    SELECT l.ItemId FROM inventory.StockDocumentLines l INNER JOIN inventory.StockDocuments d ON d.Id = l.DocumentId WHERE d.Status = 3
    UNION
    SELECT l.ItemId FROM sales.SalesDocumentLines l INNER JOIN sales.SalesDocuments d ON d.Id = l.DocumentId WHERE d.Status = 3;

    DECLARE @Started DATETIME2(3) = SYSUTCDATETIME(), @Done INT = 0,
            @ItemId INT = (SELECT MIN(i.ItemId) FROM @Items i
                           WHERE i.ItemId > (SELECT Progress FROM inventory.OneTimeSteps WHERE StepCode = N'89.ReplayCancelledDocumentItems'));
    WHILE @ItemId IS NOT NULL AND DATEDIFF(SECOND, @Started, SYSUTCDATETIME()) < 200
    BEGIN
        BEGIN TRANSACTION;
        EXEC purchase.usp_GoodsReceipt_LockMatching;
        EXEC inventory.usp_Item_RebuildCosts @ItemId;
        UPDATE inventory.OneTimeSteps SET Progress = @ItemId WHERE StepCode = N'89.ReplayCancelledDocumentItems';
        COMMIT TRANSACTION;
        SET @Done += 1;
        SET @ItemId = (SELECT MIN(ItemId) FROM @Items WHERE ItemId > @ItemId);
    END

    IF @ItemId IS NULL
        UPDATE inventory.OneTimeSteps
        SET DoneAtUtc = SYSUTCDATETIME(),
            Details = N'Items of cancelled stock and sales documents replayed: ' + CAST((SELECT COUNT(*) FROM @Items) AS NVARCHAR(10))
        WHERE StepCode = N'89.ReplayCancelledDocumentItems';
    PRINT 'Script 89: item costs replayed for ' + CAST(@Done AS NVARCHAR(10)) + ' item(s) of cancelled documents'
          + CASE WHEN @ItemId IS NULL THEN '; done.' ELSE '; the rest at the next start.' END;
END
GO

/* ================================================================== 7. inventory.usp_ShortageDocument_CreatePurchaseOrder */

-- Posted only: one draft purchase order (supplier, branch) from the lines with Required Qty > 0.
-- Re-created (89) from the body of script 22: A PLAN FOR A PARENT WAREHOUSE CREATES ITS ORDER AGAIN. Since script 70 a
-- purchase line takes a warehouse at the bottom of the tree (65000), and this procedure put the plan's warehouse - a
-- parent, which script 62 allows - on every line. Each line now takes the item's default warehouse when it is an active
-- warehouse at the bottom of the plan's tree, else the first of those (the plan's branch first, then by code); the header
-- takes its first line's (the purchase save's own rule) and the Notes say so. A plan for an active warehouse at the
-- bottom of the tree is unchanged. A tree with none refuses (66000). ONE TRANSACTION: the order, its link to the plan
-- and the plan's audit row are written together (the API retries a deadlock).
CREATE OR ALTER PROCEDURE inventory.usp_ShortageDocument_CreatePurchaseOrder
    @Id           INT,
    @DocumentDate DATE = NULL,
    @ExpectedDate DATE = NULL,
    @UserId       INT  = NULL,
    @NewId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;                                                                  -- (89)
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Status TINYINT, @BranchId INT, @WarehouseId INT, @SupplierId INT, @Number NVARCHAR(30), @Description NVARCHAR(200);
    SELECT @Status = Status, @BranchId = BranchId, @WarehouseId = WarehouseId, @SupplierId = SupplierId, @Number = DocumentNumber, @Description = Description
    FROM inventory.ShortageDocuments WHERE Id = @Id;
    IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
    IF @Status <> 2 THROW 66010, 'Post the shortage document before creating a purchase order from it.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id AND RequiredQty > 0)
        THROW 66011, 'No line has a required quantity greater than zero.', 1;

    -- (89) WHERE THE GOODS GO: the active warehouses at the bottom of the plan's tree (one at the bottom is its own tree)
    DECLARE @PlanWhCode NVARCHAR(20), @PlanWhActive BIT, @PlanWhIsLeaf BIT;
    SELECT @PlanWhCode = w.WarehouseCode, @PlanWhActive = w.IsActive, @PlanWhIsLeaf = masterdata.fn_Warehouse_IsLeaf(w.Id)
    FROM masterdata.Warehouses w WHERE w.Id = @WarehouseId;

    DECLARE @Leaves TABLE (WarehouseId INT NOT NULL PRIMARY KEY, Code NVARCHAR(20) NOT NULL, Rn INT NOT NULL);
    INSERT INTO @Leaves (WarehouseId, Code, Rn)
    SELECT w.Id, w.WarehouseCode,
           ROW_NUMBER() OVER (ORDER BY CASE WHEN w.BranchId = @BranchId THEN 0 ELSE 1 END, w.WarehouseCode, w.Id)
    FROM masterdata.fn_Warehouse_Subtree(@WarehouseId) t
    INNER JOIN masterdata.Warehouses w ON w.Id = t.Id
    WHERE w.IsActive = 1 AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1;

    DECLARE @Msg NVARCHAR(400);
    IF NOT EXISTS (SELECT 1 FROM @Leaves)
    BEGIN
        SET @Msg = CASE WHEN @PlanWhIsLeaf = 1
                        THEN N'Warehouse ' + ISNULL(@PlanWhCode, N'?') + N' of this plan is inactive. Activate it in Master Data > Warehouses, then create the purchase order again.'
                        ELSE N'Warehouse ' + ISNULL(@PlanWhCode, N'?') + N' of this plan has no active warehouse at the bottom of its tree to receive the goods into. Activate one in Master Data > Warehouses, then create the purchase order again.' END;
        THROW 66000, @Msg, 1;
    END

    DECLARE @Direct BIT = CASE WHEN @PlanWhIsLeaf = 1 AND @PlanWhActive = 1 THEN 1 ELSE 0 END;   -- as before 89
    DECLARE @FirstLeaf INT, @FirstLeafCode NVARCHAR(20);
    SELECT @FirstLeaf = WarehouseId, @FirstLeafCode = Code FROM @Leaves WHERE Rn = 1;
    DECLARE @HeaderWarehouseId INT = CASE WHEN @Direct = 1 THEN @WarehouseId END;      -- NULL: the save takes the first line's

    DECLARE @Lines purchase.tvp_PurchaseDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
    SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber), l.ItemId, l.PurchaseItemUnitId,
           CASE WHEN @Direct = 1 THEN @WarehouseId ELSE COALESCE(dl.WarehouseId, @FirstLeaf) END,           -- (89)
           NULL, l.RequiredQty, NULL, NULL, NULL,
           LEFT(N'Shortage ' + @Number + ISNULL(N' - ' + l.Notes, N''), 300), NULL
    FROM inventory.ShortageDocumentLines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    LEFT  JOIN @Leaves dl        ON dl.WarehouseId = i.DefaultWarehouseId                                 -- (89)
    WHERE l.DocumentId = @Id AND l.RequiredQty > 0;

    DECLARE @Notes NVARCHAR(1000) = LEFT(N'Created from shortage plan ' + @Number + N' - ' + @Description
        + CASE WHEN @Direct = 1 THEN N''
               ELSE N'. Warehouse ' + @PlanWhCode + N' has warehouses under it: each line goes to the item''s default warehouse when it is an active warehouse at the bottom of '
                    + @PlanWhCode + N'''s tree, else to ' + @FirstLeafCode + N'. Change them on the order if needed.' END, 1000);

    BEGIN TRY
        BEGIN TRANSACTION;                                                               -- (89)

        EXEC purchase.usp_PurchaseDocument_Save
             @Id = NULL, @DocumentTypeCode = N'PO', @DocumentDate = @DocumentDate, @ExpectedDate = @ExpectedDate,
             @BranchId = @BranchId, @WarehouseId = @HeaderWarehouseId, @SupplierId = @SupplierId, @CurrencyId = NULL,
             @RateType = 1, @ExchangeRate = NULL, @SupplierReference = NULL, @Notes = @Notes,
             @Lines = @Lines, @MaxDiscountPercent = 100, @SourceDocumentId = NULL, @RowVersion = NULL, @UserId = @UserId, @NewId = @NewId OUTPUT;

        UPDATE purchase.PurchaseDocuments SET SourceShortageId = @Id WHERE Id = @NewId;
        INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'POCreated', N'Purchase order draft created (' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s))', @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 8. Check */

-- 89a: posted stock documents whose ledger rows carry another type code than their own (expected: 0 rows; a cancel of
--      one would now be refused with 62010 "no stock movements of its own")
SELECT TOP (50) d.Id, d.DocumentNumber, DocumentType = dt.Code, RowType = m.DocumentTypeCode
FROM inventory.StockDocuments d
INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
INNER JOIN inventory.StockMovements m ON m.DocumentFamily = N'Inventory' AND m.DocumentId = d.Id
WHERE m.DocumentTypeCode <> dt.Code;
-- 89b: posted shortage plans made for a parent warehouse (they can create their purchase order again)
SELECT Check89b_PlansForAParent = COUNT(*) FROM inventory.ShortageDocuments s
WHERE s.Status = 2 AND masterdata.fn_Warehouse_IsLeaf(s.WarehouseId) = 0;
-- 89c: items the one-time replay touches whose last cost has no purchase source (they lose LastCost; expected 0 on
--      databases built from Schema.sql)
SELECT TOP (50) i.Id, i.ItemCode, i.LastCost
FROM inventory.Items i
WHERE i.LastCost IS NOT NULL
  AND i.Id IN (SELECT l.ItemId FROM inventory.StockDocumentLines l INNER JOIN inventory.StockDocuments d ON d.Id = l.DocumentId WHERE d.Status = 3
               UNION SELECT l.ItemId FROM sales.SalesDocumentLines l INNER JOIN sales.SalesDocuments d ON d.Id = l.DocumentId WHERE d.Status = 3)
  AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines gl INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId AND g.Status = 2 WHERE gl.ItemId = i.Id)
  AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines pl INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pl.DocumentId
                  WHERE pl.ItemId = i.Id AND pd.Status = 2 AND pd.UsesGoodsReceipts = 0)
  AND NOT EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ItemId = i.Id AND cl.ReceivedQuantityBase > 0);
-- 89d: the one-time step, and the document types whose settings are now kept
SELECT StepCode, StartedAtUtc, DoneAtUtc, Progress, Details FROM inventory.OneTimeSteps;
SELECT Code, UpdatedAtUtc FROM inventory.DocumentTypes WHERE UpdatedAtUtc IS NOT NULL ORDER BY Code;
PRINT 'Script 89 applied: late charges and old landed cost adjustments split on company stock; stock and sales cancels replay costs; a parent plan creates its order; document type settings are kept.';
GO
