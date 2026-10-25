/* ================================================================== 14. The cost replay: a transfer moves no cost */

-- Re-created (90) from the body of script 79: + the incoming legs of a transfer (family Transfer, quantity above 0: the
-- On the way warehouse at a dispatch, the destination at a receipt) enter at the RUNNING AVERAGE, not at the cost frozen
-- on the row (FB rule 34). The receipt branch reads ISNULL(@ECost, @Avg): a NULL cost leaves the average where it is,
-- whatever the running balance. The outgoing legs and the losses (TRF_LOSS) are issues, as every out: the average does
-- not move. A reversed posting is left out with its reversal, as every family's. Every other family reads
-- m.UnitCostBase as before, so the replay of a database without transfers gives the same costs as before.
CREATE   PROCEDURE inventory.usp_Item_RebuildCosts
    @ItemId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Events TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ItemId INT, Qty INT, Cost DECIMAL(18,6), Amount DECIMAL(18,2));
    INSERT INTO @Events (ItemId, Qty, Cost, Amount)
    SELECT x.ItemId, x.Qty, x.Cost, x.Amount
    FROM
    (
        SELECT m.ItemId, EventDate = m.MovementDate, Src = 1, SrcId = m.Id, Qty = m.QuantityBase,
               -- (90) A TRANSFER MOVES NO COST: its incoming legs (On the way, the destination) enter at the running average.
               Cost = CASE WHEN m.DocumentFamily = N'Transfer' AND m.QuantityBase > 0 THEN NULL ELSE m.UnitCostBase END,
               Amount = CAST(NULL AS DECIMAL(18,2))
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
                         -- (79) a line without an order - manual, or from an invoice that does not change item
                         --      costs - counts once matched to an invoice that does: its cost is not a purchase price
                         AND NOT (gl.PoLineId IS NULL
                                  AND (gl.InvoiceLineId IS NULL
                                       OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines p
                                                  INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = p.DocumentId
                                                  WHERE p.Id = gl.InvoiceLineId AND pd.AffectsCost = 0))
                                  AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceiptInvoiceMatches x
                                                  INNER JOIN purchase.PurchaseDocumentLines p ON p.Id = x.InvoiceLineId
                                                  INNER JOIN purchase.PurchaseDocuments pd    ON pd.Id = p.DocumentId
                                                  WHERE x.GoodsReceiptLineId = gl.Id AND pd.AffectsCost = 1))) r
                 ORDER BY r.ReceivedAtUtc DESC, r.Tie DESC) x
    WHERE (@ItemId IS NULL OR i.Id = @ItemId);
END

GO

