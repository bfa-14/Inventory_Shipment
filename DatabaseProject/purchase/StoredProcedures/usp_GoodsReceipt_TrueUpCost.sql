/* ================================================================== 5b. The items a true-up replays */

-- Re-created (79) from the body of script 64: the items it replays (usp_Item_RebuildCosts) include those of the lines
-- of an order-less invoice that does not change item costs, as they do the manual lines. Nothing else changes.
/* BRINGS POSTED RECEIPT LINES TO THEIR TARGET COST (fn_GoodsReceiptLine_TargetCost), after anything that changed
   their matches or their invoices' cost: an invoice or an LCA posted or cancelled, a goods receipt posted or cancelled.
   Acts on the lines whose target FOB (container lines) or target landed cost (other lines) differs from the current
   one by 0.000001 or more.
     Amount     container line: ROUND((target FOB - cl.FobCostBase) x R, 2) - only the FOB moves, its charges are
                the container's (a matched local invoice's own charges ride on that FOB, see the target cost); other
                lines: ROUND((target landed - UnitCostBase) x R, 2)
     Split      per ITEM over the lines of this event: Remaining = min(sum of the lines' net received pieces, company
                stock on hand); the stock part = Amount x (1 - returned share) x Remaining / net received (cents left
                over by rounding on the line with the largest amount), the rest to cost of sales. No stock left: all to
                cost of sales. Company stock, not the warehouse's (unlike the container late charge and the LCA): the
                average is company-wide and transfers move goods out of the receiving warehouse. The RETURNED SHARE is
                for an LCA (or its cancel) only: it re-prices the pieces matched to the adjustment's invoice lines, and
                the returned ones among them are not in stock any more - their share goes to cost of sales, as the old
                LCA did (Allocated / Qty x Remaining). The other causes re-price only pieces whose match is new or
                removed, never returned ones (a return takes back matched pieces only).
     Records    one GoodsReceiptCostChanges row per line with an amount (its Id = CostAdjustments.SourceId), and
                inventory.CostAdjustments Inventory / COGS rows (SourceKind GRNCOST, SourceNumber = the GRN), dated
                at the later of now and the receipt's own ledger date, so that no replay puts it before its receipt.
                Compensating rows are written as they come (negative amounts included).
     Costs      container lines: cl.FobCostBase, then usp_Container_RecalcCosts; other lines: FobCostBase /
                ChargesBase / UnitCostBase / CostSource. Then usp_Item_RebuildCosts per item, as the late container
                charge does - also for the items of the posted MANUAL lines given ("Without an order"), adjusted or
                not: the caller's rematch may have matched or unmatched one at its typed cost, and such a line counts for
                the last cost, FOB cost and last supplier only once matched (rules 16, 24).
   Takes the matching lock (usp_GoodsReceipt_LockMatching): its callers already hold it, taken first.
   The totals come back in the OUTPUT parameters (no result set): for the invoice audit, the API message. */
CREATE   PROCEDURE purchase.usp_GoodsReceipt_TrueUpCost
    @LineIds       logistics.tvp_IdList READONLY,     -- goods receipt line ids (other lines and unposted receipts are ignored)
    @CauseKind     NVARCHAR(12),                      -- PINV | PINVCANCEL | LCA | LCACANCEL | GRNPOST | GRNCANCEL
    @CauseId       INT           = NULL,              -- the invoice, LCA or goods receipt
    @CauseNumber   NVARCHAR(30)  = NULL,
    @UserId        INT           = NULL,
    @AmountBase    DECIMAL(18,2) = NULL OUTPUT,
    @InventoryBase DECIMAL(18,2) = NULL OUTPUT,
    @CogsBase      DECIMAL(18,2) = NULL OUTPUT,
    @LinesAdjusted INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT @AmountBase = 0, @InventoryBase = 0, @CogsBase = 0, @LinesAdjusted = 0;
    IF @CauseKind IS NULL OR @CauseKind NOT IN (N'PINV', N'PINVCANCEL', N'LCA', N'LCACANCEL', N'GRNPOST', N'GRNCANCEL', N'NEGSTOCK')
        THROW 63000, 'Unknown cause of a goods receipt cost adjustment.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @W TABLE (LineId INT NOT NULL PRIMARY KEY, GoodsReceiptId INT NOT NULL, Number NVARCHAR(30) NOT NULL, ItemId INT NOT NULL,
                          WarehouseId INT NOT NULL, BranchId INT NOT NULL, ContainerLineId INT NULL, ContainerId INT NULL, IsContainer BIT NOT NULL,
                          R INT NOT NULL, RNet DECIMAL(18,6) NOT NULL,
                          FobBefore DECIMAL(18,6) NOT NULL, FobAfter DECIMAL(18,6) NOT NULL,
                          CostBefore DECIMAL(18,6) NOT NULL, CostAfter DECIMAL(18,6) NOT NULL, ChargesAfter DECIMAL(18,6) NOT NULL,
                          CostSource NVARCHAR(10) NULL,
                          Amount DECIMAL(18,2) NOT NULL DEFAULT (0), Inv DECIMAL(18,2) NOT NULL DEFAULT (0), InStock DECIMAL(18,6) NOT NULL DEFAULT (0),
                          RetShare DECIMAL(18,10) NOT NULL DEFAULT (0));

        INSERT INTO @W (LineId, GoodsReceiptId, Number, ItemId, WarehouseId, BranchId, ContainerLineId, ContainerId, IsContainer, R, RNet,
                        FobBefore, FobAfter, CostBefore, CostAfter, ChargesAfter, CostSource)
        SELECT t.GoodsReceiptLineId, t.GoodsReceiptId, g.DocumentNumber, t.ItemId, t.WarehouseId, w.BranchId, t.ContainerLineId, t.ContainerId,
               t.IsContainerLine, t.ReceivedBase, t.NetReceivedBase,
               t.CurrentFobBase, t.TargetFobBase, t.CurrentUnitCostBase, t.TargetUnitCostBase, t.TargetChargesBase, t.CostSource
        FROM (SELECT DISTINCT gl.GoodsReceiptId FROM @LineIds x INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = x.Id) r
        CROSS APPLY purchase.fn_GoodsReceiptLine_TargetCost(r.GoodsReceiptId) t
        INNER JOIN purchase.GoodsReceipts g    ON g.Id = t.GoodsReceiptId
        INNER JOIN masterdata.Warehouses w     ON w.Id = t.WarehouseId
        WHERE EXISTS (SELECT 1 FROM @LineIds x WHERE x.Id = t.GoodsReceiptLineId)
          AND t.CurrentFobBase IS NOT NULL AND t.CurrentUnitCostBase IS NOT NULL       -- set by every posting
          AND (ABS(t.TargetFobBase - t.CurrentFobBase) >= 0.000001
               OR (t.IsContainerLine = 0 AND ABS(t.TargetUnitCostBase - t.CurrentUnitCostBase) >= 0.000001));

        IF EXISTS (SELECT 1 FROM @W)
        BEGIN
            UPDATE @W SET Amount = ROUND(CASE WHEN IsContainer = 1 THEN FobAfter - FobBefore ELSE CostAfter - CostBefore END * R, 2);

            -- (LCA / LCACANCEL) THE RETURNED SHARE of what this event re-prices: the line's pieces matched to the
            -- adjustment's invoice lines, weighted by what the adjustment adds per piece of each, and of those the share
            -- returned from each invoice line (spread over its matches, as the net received is). Returned pieces are no
            -- longer in stock: that share goes to cost of sales whatever the stock, as the old LCA did. The adjustment's
            -- lines exist at both calls (Post inserts them first, Cancel keeps them). The other causes re-price only
            -- pieces whose match is new or removed, never a returned one.
            UPDATE w SET RetShare = ISNULL(x.Ret / NULLIF(x.Qty, 0), 0)
            FROM @W w
            CROSS APPLY (SELECT Qty = SUM(CAST(m.QuantityBase AS DECIMAL(18,6)) * ABS(a.ExtraPerBaseUnit)),
                                Ret = SUM(CAST(m.QuantityBase AS DECIMAL(18,6)) * ABS(a.ExtraPerBaseUnit)
                                          * CASE WHEN p.ReturnedQuantityBase < p.ReceivedQuantityBase THEN p.ReturnedQuantityBase
                                                 ELSE p.ReceivedQuantityBase END
                                          / NULLIF(p.ReceivedQuantityBase, 0))
                         FROM purchase.GoodsReceiptInvoiceMatches m
                         INNER JOIN purchase.PurchaseDocumentLines p     ON p.Id = m.InvoiceLineId
                         INNER JOIN purchase.LandedCostAdjustmentLines a ON a.PurchaseLineId = p.Id AND a.AdjustmentId = @CauseId
                         WHERE m.GoodsReceiptLineId = w.LineId) x
            WHERE @CauseKind IN (N'LCA', N'LCACANCEL');

            -- the part still in stock, per item for the whole event, on company stock
            DECLARE @Items TABLE (ItemId INT NOT NULL PRIMARY KEY, NetReceived DECIMAL(18,6) NOT NULL, OnHand DECIMAL(18,6) NOT NULL,
                                  Remaining DECIMAL(18,6) NULL, Amount DECIMAL(18,2) NOT NULL, Inv DECIMAL(18,2) NULL);
            INSERT INTO @Items (ItemId, NetReceived, OnHand, Amount)
            SELECT ItemId, SUM(CASE WHEN RNet > 0 THEN RNet ELSE 0 END), inventory.fn_StockOnHand(ItemId, NULL), SUM(Amount)
            FROM @W GROUP BY ItemId;

            UPDATE @Items SET Remaining = CASE WHEN OnHand <= 0 OR NetReceived <= 0 THEN 0
                                               WHEN OnHand < NetReceived THEN OnHand ELSE NetReceived END;

            -- the stock part of the amount that can still be in stock (all of it, but for the returned share above)
            UPDATE w
            SET Inv     = CASE WHEN i.Remaining = 0 THEN 0 ELSE ROUND(w.Amount * (1 - w.RetShare) * i.Remaining / i.NetReceived, 2) END,
                InStock = CASE WHEN i.Remaining = 0 OR w.RNet <= 0 THEN 0 ELSE w.RNet * i.Remaining / i.NetReceived END
            FROM @W w INNER JOIN @Items i ON i.ItemId = w.ItemId;

            UPDATE i
            SET Inv = CASE WHEN i.Remaining = 0 THEN 0 ELSE ROUND(x.Eligible * i.Remaining / i.NetReceived, 2) END
            FROM @Items i
            CROSS APPLY (SELECT Eligible = SUM(w.Amount * (1 - w.RetShare)) FROM @W w WHERE w.ItemId = i.ItemId) x;

            -- the cents lost by rounding the lines go to the line of the item with the largest amount
            WITH d AS (SELECT w.LineId, Diff = i.Inv - SUM(w.Inv) OVER (PARTITION BY w.ItemId),
                              Rn = ROW_NUMBER() OVER (PARTITION BY w.ItemId ORDER BY ABS(w.Amount) DESC, w.LineId)
                       FROM @W w INNER JOIN @Items i ON i.ItemId = w.ItemId)
            UPDATE w SET Inv = w.Inv + d.Diff
            FROM @W w INNER JOIN d ON d.LineId = w.LineId
            WHERE d.Rn = 1 AND d.Diff <> 0;

            DECLARE @Changes TABLE (ChangeId INT NOT NULL PRIMARY KEY, LineId INT NOT NULL);
            INSERT INTO purchase.GoodsReceiptCostChanges (GoodsReceiptLineId, CauseKind, CauseId, CauseNumber, ReceivedBase, InStockBase,
                                                          FobBefore, FobAfter, UnitCostBefore, UnitCostAfter, AmountBase, InventoryBase, CogsBase, CreatedBy)
            OUTPUT inserted.Id, inserted.GoodsReceiptLineId INTO @Changes (ChangeId, LineId)
            SELECT LineId, @CauseKind, @CauseId, @CauseNumber, R, InStock, FobBefore, FobAfter, CostBefore, CostAfter, Amount, Inv, Amount - Inv, @UserId
            FROM @W WHERE Amount <> 0;

            INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
            SELECT CASE WHEN md.D > SYSUTCDATETIME() THEN md.D ELSE SYSUTCDATETIME() END,
                   w.ItemId, w.WarehouseId, w.BranchId, k.Kind, k.Amount, N'GRNCOST', c.ChangeId, w.Number, NULL, @UserId
            FROM @W w
            INNER JOIN @Changes c ON c.LineId = w.LineId
            OUTER APPLY (SELECT D = MAX(m.MovementDate) FROM inventory.StockMovements m
                         WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'GRN' AND m.DocumentId = w.GoodsReceiptId
                           AND m.IsReversal = 0) md
            CROSS APPLY (VALUES (N'Inventory', w.Inv), (N'COGS', w.Amount - w.Inv)) k (Kind, Amount)
            WHERE k.Amount <> 0;

            -- the new current cost: on the container line for container lines (its landed cost follows), else on the line
            UPDATE cl SET FobCostBase = w.FobAfter
            FROM logistics.ContainerLines cl INNER JOIN @W w ON w.ContainerLineId = cl.Id
            WHERE w.IsContainer = 1;

            UPDATE gl
            SET FobCostBase  = CASE WHEN w.IsContainer = 1 THEN gl.FobCostBase ELSE w.FobAfter END,
                ChargesBase  = CASE WHEN w.IsContainer = 1 THEN gl.ChargesBase ELSE w.ChargesAfter END,
                UnitCostBase = CASE WHEN w.IsContainer = 1 THEN gl.UnitCostBase ELSE w.CostAfter END,
                CostSource   = w.CostSource
            FROM purchase.GoodsReceiptLines gl INNER JOIN @W w ON w.LineId = gl.Id;

            DECLARE @ContainerId INT;
            DECLARE cts CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ContainerId FROM @W WHERE IsContainer = 1;
            OPEN cts;
            FETCH NEXT FROM cts INTO @ContainerId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_RecalcCosts @ContainerId;
                FETCH NEXT FROM cts INTO @ContainerId;
            END
            CLOSE cts;
            DEALLOCATE cts;

            INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId)
            SELECT w.GoodsReceiptId, N'CostAdjusted',
                   LEFT(N'Cost adjusted by ' + ISNULL(@CauseNumber + N' ', N'')
                        + N'(' + CASE @CauseKind WHEN N'PINV' THEN N'invoice posted'
                                                 WHEN N'PINVCANCEL' THEN N'invoice cancelled'
                                                 WHEN N'LCA' THEN N'landed cost adjustment posted'
                                                 WHEN N'LCACANCEL' THEN N'landed cost adjustment cancelled'
                                                 WHEN N'GRNPOST' THEN N'goods receipt posted'
                                                 WHEN N'GRNCANCEL' THEN N'goods receipt cancelled'
                                                 ELSE N'negative stock filled' END
                        + N'): ' + CAST(SUM(w.Amount) AS NVARCHAR(30)) + N' (stock ' + CAST(SUM(w.Inv) AS NVARCHAR(30))
                        + N', cost of sales ' + CAST(SUM(w.Amount - w.Inv) AS NVARCHAR(30)) + N')', 500),
                   @UserId
            FROM @W w
            GROUP BY w.GoodsReceiptId
            HAVING SUM(CASE WHEN w.Amount <> 0 THEN 1 ELSE 0 END) > 0;

            SELECT @AmountBase = ISNULL(SUM(Amount), 0), @InventoryBase = ISNULL(SUM(Inv), 0), @CogsBase = ISNULL(SUM(Amount - Inv), 0),
                   @LinesAdjusted = SUM(CASE WHEN Amount <> 0 THEN 1 ELSE 0 END)
            FROM @W;
        END

        -- ITEM COSTS REPLAYED: the items of the adjusted lines, and those of the posted MANUAL lines given, adjusted or
        -- not. The caller's rematch can match or unmatch a manual line without changing its cost (an invoice at the
        -- typed price), and such a line counts for the last cost, FOB cost and last supplier only once matched (rules
        -- 16, 24): its item is replayed either way. (@Items is empty when nothing was adjusted.)
        -- (79) The same for a posted line of an order-less invoice that does not change item costs: it counts for the
        --      last cost only once matched to an invoice that does (usp_Item_RebuildCosts), and a match gained or lost
        --      at the same price moves no cost, so nothing above would replay its item.
        DECLARE @ItemId INT;
        DECLARE items CURSOR LOCAL FAST_FORWARD FOR
            SELECT ItemId FROM @Items
            UNION
            SELECT gl.ItemId
            FROM @LineIds x
            INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = x.Id
            INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId AND g.Status = 2
            WHERE gl.PoLineId IS NULL AND gl.QuantityBase > 0
              AND (gl.InvoiceLineId IS NULL
                   OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines p
                              INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = p.DocumentId
                              WHERE p.Id = gl.InvoiceLineId AND pd.AffectsCost = 0));
        OPEN items;
        FETCH NEXT FROM items INTO @ItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC inventory.usp_Item_RebuildCosts @ItemId;
            FETCH NEXT FROM items INTO @ItemId;
        END
        CLOSE items;
        DEALLOCATE items;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

