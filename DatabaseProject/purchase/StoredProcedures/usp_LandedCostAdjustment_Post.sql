/* ================================================================== 3. purchase.usp_LandedCostAdjustment_Post */

-- Re-created (89) from the body of script 79: on an invoice posted before goods receipts THE PART STILL IN STOCK IS
-- CAPPED BY THE COMPANY'S STOCK OF THE ITEM, per item over the adjusted lines (as the goods receipt true-up does), no
-- longer by each line's warehouse; the lines' rounded Remaining add up to the item's. An invoice that uses goods
-- receipts is unchanged (its true-up rewrites these figures).
CREATE   PROCEDURE purchase.usp_LandedCostAdjustment_Post
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

