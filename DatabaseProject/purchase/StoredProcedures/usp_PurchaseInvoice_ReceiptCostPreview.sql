/* ================================================================== 10. The post confirmation's estimate */

-- Re-created (79) from the body of script 78: when the PINV type does not change item costs, the received pieces keep
-- their cost (no difference, no estimate), and each row says so (AffectsCost).
CREATE   PROCEDURE purchase.usp_PurchaseInvoice_ReceiptCostPreview
    @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status TINYINT, @Rate DECIMAL(18,6), @SupplierId INT, @Code NVARCHAR(20), @Affects BIT;
    -- (79) a draft follows its type: AffectsItemCost as it is now is what the posting will capture
    SELECT @Status = d.Status, @Rate = d.ExchangeRate, @SupplierId = d.SupplierId, @Code = dt.Code, @Affects = dt.AffectsItemCost
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE d.Id = @InvoiceId;
    IF @Status IS NULL OR @Code <> N'PINV' THROW 65006, 'Purchase invoice not found.', 1;

    -- the draft's own charges per line: as allocated, else shared by value (an estimate until it is posted)
    DECLARE @ChargesTotal DECIMAL(18,2) = ISNULL((SELECT SUM(AmountBase) FROM purchase.PurchaseCharges
                                                  WHERE DocumentKind = N'PINV' AND DocumentId = @InvoiceId AND IncludeInLandedCost = 1), 0);
    DECLARE @HasAllocations BIT = CASE WHEN EXISTS (SELECT 1 FROM purchase.PurchaseChargeAllocations x
                                                    INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                                                    WHERE c.DocumentKind = N'PINV' AND c.DocumentId = @InvoiceId AND c.IncludeInLandedCost = 1)
                                       THEN 1 ELSE 0 END;
    DECLARE @ValueTotal DECIMAL(18,6) = (SELECT SUM(LineTotal / @Rate) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);

    DECLARE @L TABLE (LineId INT NOT NULL PRIMARY KEY, LineNumber INT NOT NULL, ItemId INT NOT NULL, GroupKey NVARCHAR(40) NOT NULL,
                      ContainerLineId INT NULL, QuantityBase INT NOT NULL, FobBase DECIMAL(18,6) NOT NULL, ChargesBase DECIMAL(18,6) NOT NULL,
                      Rem INT NOT NULL);
    INSERT INTO @L (LineId, LineNumber, ItemId, GroupKey, ContainerLineId, QuantityBase, FobBase, ChargesBase, Rem)
    SELECT l.Id, l.LineNumber, l.ItemId,
           CASE WHEN l.SourceLineId IS NOT NULL THEN N'P' + CAST(l.SourceLineId AS NVARCHAR(12))
                ELSE N'S' + CAST(@SupplierId AS NVARCHAR(12)) + N'.' + CAST(l.ItemId AS NVARCHAR(12)) END,
           l.ContainerLineId, l.QuantityBase,
           CAST(l.LineTotal / @Rate / l.QuantityBase AS DECIMAL(18,6)),
           CAST(CASE WHEN @HasAllocations = 1
                     THEN ISNULL((SELECT SUM(x.AmountBase) FROM purchase.PurchaseChargeAllocations x
                                  INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                                  WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'PINV' AND c.DocumentId = @InvoiceId
                                    AND c.IncludeInLandedCost = 1), 0)
                     WHEN @ValueTotal > 0 THEN @ChargesTotal * (l.LineTotal / @Rate) / @ValueTotal
                     ELSE 0 END / l.QuantityBase AS DECIMAL(18,6)),
           -- a line of a container offloaded before goods receipts takes nothing: its goods are received already
           CASE WHEN rb.ReceivedBy = N'Offload' THEN 0 ELSE l.QuantityBase END
    FROM purchase.PurchaseDocumentLines l
    LEFT JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
    OUTER APPLY logistics.fn_Container_ReceivedBy(cl.ContainerId) rb
    WHERE l.DocumentId = @InvoiceId AND @Status = 1;

    -- received pieces of those groups not matched to an invoice yet, with what they cost now
    DECLARE @U TABLE (LineId INT NOT NULL PRIMARY KEY, GoodsReceiptId INT NOT NULL, GroupKey NVARCHAR(40) NOT NULL, ContainerLineId INT NULL,
                      ItemId INT NOT NULL, T DATETIME2(3) NOT NULL, Rem INT NOT NULL, IsContainer BIT NOT NULL,
                      BaseFob DECIMAL(18,6) NOT NULL, BaseCharges DECIMAL(18,6) NOT NULL, ContainerCharges DECIMAL(18,6) NOT NULL,
                      RNet DECIMAL(18,6) NOT NULL);
    INSERT INTO @U (LineId, GoodsReceiptId, GroupKey, ContainerLineId, ItemId, T, Rem, IsContainer, BaseFob, BaseCharges, ContainerCharges, RNet)
    SELECT t.GoodsReceiptLineId, t.GoodsReceiptId,
           CASE WHEN t.PoLineId IS NOT NULL THEN N'P' + CAST(t.PoLineId AS NVARCHAR(12))
                ELSE N'S' + CAST(t.SupplierId AS NVARCHAR(12)) + N'.' + CAST(t.ItemId AS NVARCHAR(12)) END,
           t.ContainerLineId, t.ItemId, ISNULL(g.PostedAtUtc, g.CreatedAtUtc), t.ReceivedBase - t.MatchedBase, t.IsContainerLine,
           t.BaseFobBase, t.BaseChargesBase, CASE WHEN t.IsContainerLine = 1 THEN t.TargetChargesBase ELSE 0 END, t.NetReceivedBase
    FROM (SELECT DISTINCT gl.GoodsReceiptId
          FROM purchase.GoodsReceiptLines gl
          INNER JOIN purchase.GoodsReceipts gr ON gr.Id = gl.GoodsReceiptId AND gr.Status = 2
          WHERE gl.PoLineId IN (SELECT l.SourceLineId FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @InvoiceId)
             OR (gl.PoLineId IS NULL AND gl.SupplierId = @SupplierId
                 AND gl.ItemId IN (SELECT l.ItemId FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @InvoiceId AND l.SourceLineId IS NULL))) r
    CROSS APPLY purchase.fn_GoodsReceiptLine_TargetCost(r.GoodsReceiptId) t
    INNER JOIN purchase.GoodsReceipts g ON g.Id = t.GoodsReceiptId
    WHERE t.ReceivedBase > t.MatchedBase;

    DELETE FROM @U WHERE GroupKey NOT IN (SELECT GroupKey FROM @L);

    -- first in first out, as the rematch would: the container line first, then the group
    DECLARE @Take TABLE (ULineId INT NOT NULL, LLineId INT NOT NULL, Qty INT NOT NULL);
    DECLARE @Pass TABLE (ULineId INT NOT NULL, LLineId INT NOT NULL, Qty INT NOT NULL);

    WITH u AS (SELECT LineId, K = ContainerLineId, Rem,
                      E = SUM(Rem) OVER (PARTITION BY ContainerLineId ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
               FROM @U WHERE Rem > 0 AND ContainerLineId IS NOT NULL),
         l AS (SELECT LineId, K = ContainerLineId, Rem,
                      E = SUM(Rem) OVER (PARTITION BY ContainerLineId ORDER BY LineNumber ROWS UNBOUNDED PRECEDING)
               FROM @L WHERE Rem > 0 AND ContainerLineId IS NOT NULL)
    INSERT INTO @Pass (ULineId, LLineId, Qty)
    SELECT u.LineId, l.LineId,
           (CASE WHEN u.E < l.E THEN u.E ELSE l.E END) - (CASE WHEN u.E - u.Rem > l.E - l.Rem THEN u.E - u.Rem ELSE l.E - l.Rem END)
    FROM u INNER JOIN l ON l.K = u.K
    WHERE u.E - u.Rem < l.E AND l.E - l.Rem < u.E;

    UPDATE u SET Rem = u.Rem - p.Qty FROM @U u INNER JOIN (SELECT ULineId, Qty = SUM(Qty) FROM @Pass GROUP BY ULineId) p ON p.ULineId = u.LineId;
    UPDATE l SET Rem = l.Rem - p.Qty FROM @L l INNER JOIN (SELECT LLineId, Qty = SUM(Qty) FROM @Pass GROUP BY LLineId) p ON p.LLineId = l.LineId;
    INSERT INTO @Take (ULineId, LLineId, Qty) SELECT ULineId, LLineId, Qty FROM @Pass;
    DELETE FROM @Pass;

    WITH u AS (SELECT LineId, K = GroupKey, Rem,
                      E = SUM(Rem) OVER (PARTITION BY GroupKey ORDER BY T, LineId ROWS UNBOUNDED PRECEDING)
               FROM @U WHERE Rem > 0),
         l AS (SELECT LineId, K = GroupKey, Rem,
                      E = SUM(Rem) OVER (PARTITION BY GroupKey ORDER BY LineNumber ROWS UNBOUNDED PRECEDING)
               FROM @L WHERE Rem > 0)
    INSERT INTO @Take (ULineId, LLineId, Qty)
    SELECT u.LineId, l.LineId,
           (CASE WHEN u.E < l.E THEN u.E ELSE l.E END) - (CASE WHEN u.E - u.Rem > l.E - l.Rem THEN u.E - u.Rem ELSE l.E - l.Rem END)
    FROM u INNER JOIN l ON l.K = u.K
    WHERE u.E - u.Rem < l.E AND l.E - l.Rem < u.E;

    -- per piece taken: now = its base cost (+ its container's charges); with the invoice = the invoice FOB + the invoice's
    -- own charges (+ the same container charges for container pieces: fn_GoodsReceiptLine_TargetCost)
    DECLARE @T TABLE (LLineId INT NOT NULL, ULineId INT NOT NULL, ItemId INT NOT NULL, Qty INT NOT NULL,
                      CostNow DECIMAL(18,6) NOT NULL, CostNew DECIMAL(18,6) NOT NULL, PRIMARY KEY (LLineId, ULineId));
    INSERT INTO @T (LLineId, ULineId, ItemId, Qty, CostNow, CostNew)
    SELECT k.LLineId, k.ULineId, u.ItemId, SUM(k.Qty),
           MAX(CASE WHEN u.IsContainer = 1 THEN u.BaseFob + u.ContainerCharges ELSE u.BaseFob + u.BaseCharges END),
           MAX(CASE WHEN u.IsContainer = 1 THEN l.FobBase + l.ChargesBase + u.ContainerCharges ELSE l.FobBase + l.ChargesBase END)
    FROM @Take k
    INNER JOIN @U u ON u.LineId = k.ULineId
    INNER JOIN @L l ON l.LineId = k.LLineId
    GROUP BY k.LLineId, k.ULineId, u.ItemId;

    -- (79) an invoice that does not change item costs leaves the received pieces at their cost: no difference
    IF @Affects = 0 UPDATE @T SET CostNew = CostNow;

    -- the stock share per item, on today's company stock, over the receipt lines involved (as the true-up)
    DECLARE @Items TABLE (ItemId INT NOT NULL PRIMARY KEY, NetReceived DECIMAL(18,6) NOT NULL, OnHand DECIMAL(18,6) NOT NULL, Ratio DECIMAL(18,10) NOT NULL);
    INSERT INTO @Items (ItemId, NetReceived, OnHand, Ratio)
    SELECT x.ItemId, x.NetReceived, oh.Q,
           CASE WHEN oh.Q <= 0 OR x.NetReceived <= 0 THEN 0 WHEN oh.Q < x.NetReceived THEN oh.Q / x.NetReceived ELSE 1 END
    FROM (SELECT u.ItemId, NetReceived = SUM(CASE WHEN u.RNet > 0 THEN u.RNet ELSE 0 END)
          FROM @U u WHERE u.LineId IN (SELECT ULineId FROM @T) GROUP BY u.ItemId) x
    CROSS APPLY (SELECT Q = CAST(inventory.fn_StockOnHand(x.ItemId, NULL) AS DECIMAL(18,6))) oh;

    SELECT InvoiceLineId           = l.Id,
           l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           InvoicedBase            = l.QuantityBase,
           ReceivedNotInvoicedBase = ISNULL(x.Qty, 0),
           CurrentCostBase         = CAST(x.Now / NULLIF(x.Qty, 0) AS DECIMAL(18,6)),
           InvoiceCostBase         = CAST(x.New / NULLIF(x.Qty, 0) AS DECIMAL(18,6)),
           DifferenceBase          = CAST(ISNULL(x.Diff, 0) AS DECIMAL(18,2)),
           EstimatedInventoryBase  = CAST(ROUND(ISNULL(x.Diff, 0) * ISNULL(it.Ratio, 0), 2) AS DECIMAL(18,2)),
           EstimatedCogsBase       = CAST(ISNULL(x.Diff, 0) - ROUND(ISNULL(x.Diff, 0) * ISNULL(it.Ratio, 0), 2) AS DECIMAL(18,2)),
           CompanyOnHandBase       = CAST(inventory.fn_StockOnHand(l.ItemId, NULL) AS INT),
           Receipts                = x.Receipts,
           IsEstimate              = CAST(1 AS BIT),
           AffectsCost             = @Affects      -- (79)
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    OUTER APPLY (SELECT Qty  = SUM(t.Qty),
                        Now  = SUM(t.Qty * t.CostNow),
                        New  = SUM(t.Qty * t.CostNew),
                        Diff = SUM(ROUND((t.CostNew - t.CostNow) * t.Qty, 2)),
                        -- (78) at most 10 numbers, else the first 5 and "+N more" (NVARCHAR(MAX): 9829 above about 210)
                        Receipts = (SELECT CAST(STRING_AGG(CASE WHEN z.N <= 10 OR z.Rn <= 5 THEN CAST(z.DocumentNumber AS NVARCHAR(MAX)) END, N', ')
                                                    WITHIN GROUP (ORDER BY z.DocumentNumber)
                                                + CASE WHEN MAX(z.N) > 10 THEN N' +' + CAST(MAX(z.N) - 5 AS NVARCHAR(10)) + N' more' ELSE N'' END
                                                AS NVARCHAR(400))
                                    FROM (SELECT y.DocumentNumber, Rn = ROW_NUMBER() OVER (ORDER BY y.DocumentNumber), N = COUNT(*) OVER ()
                                          FROM (SELECT DISTINCT g.DocumentNumber FROM @T t2
                                                INNER JOIN @U u2 ON u2.LineId = t2.ULineId
                                                INNER JOIN purchase.GoodsReceipts g ON g.Id = u2.GoodsReceiptId
                                                WHERE t2.LLineId = l.Id) y) z)
                 FROM @T t WHERE t.LLineId = l.Id) x
    LEFT JOIN @Items it ON it.ItemId = l.ItemId
    WHERE l.DocumentId = @InvoiceId AND @Status = 1
    ORDER BY l.LineNumber;
END

GO

