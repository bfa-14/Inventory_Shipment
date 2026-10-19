-- (their pieces are estimated at the order price), as the posting will (section 3).
CREATE   FUNCTION purchase.fn_GoodsReceiptLine_Cost (@GoodsReceiptId INT)
RETURNS TABLE
AS
RETURN
    SELECT LineId         = l.Id,
           l.GoodsReceiptId,
           OrderPriceBase = CAST(op.Price AS DECIMAL(18,6)),
           FobBase        = CAST(y.Fob AS DECIMAL(18,6)),
           ChargesBase    = CAST(y.Charges AS DECIMAL(18,6)),
           UnitCostBase   = CAST(z.Unit AS DECIMAL(18,6)),
           IsEstimate     = CAST(CASE WHEN g.Status = 1 THEN 1 ELSE 0 END AS BIT),
           ValueBase      = CAST(ROUND(CAST(l.QuantityBase AS DECIMAL(18,6)) * ISNULL(z.Unit, 0), 2) AS DECIMAL(18,2))
    FROM purchase.GoodsReceiptLines l
    INNER JOIN purchase.GoodsReceipts g             ON g.Id = l.GoodsReceiptId
    LEFT  JOIN logistics.ContainerLines cl          ON cl.Id = l.ContainerLineId
    LEFT  JOIN purchase.PurchaseDocumentLines pol   ON pol.Id = l.PoLineId
    LEFT  JOIN purchase.PurchaseDocuments po        ON po.Id = pol.DocumentId
    LEFT  JOIN purchase.PurchaseDocumentLines pil   ON pil.Id = l.InvoiceLineId
    LEFT  JOIN purchase.PurchaseDocuments pid       ON pid.Id = pil.DocumentId AND pid.Status IN (2, 4) AND pid.AffectsCost = 1
    LEFT  JOIN inventory.Items it                   ON it.Id = l.ItemId
    OUTER APPLY (SELECT Price = COALESCE(l.PoFobBase,
                                         pol.LineTotal / NULLIF(po.ExchangeRate, 0) / NULLIF(pol.QuantityBase, 0))) op
    OUTER APPLY (SELECT Fob = SUM(x.LineTotal / NULLIF(xd.ExchangeRate, 0)) / NULLIF(SUM(x.QuantityBase), 0)
                 FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId AND xd.Status IN (2, 4) AND xd.AffectsCost = 1
                 WHERE l.ContainerLineId IS NOT NULL AND g.Status = 1 AND x.ContainerLineId = l.ContainerLineId) ci
    CROSS APPLY (SELECT Fob = CASE WHEN g.Status = 3 THEN NULL
                                   WHEN g.Status = 2 AND l.ContainerLineId IS NOT NULL THEN cl.FobCostBase
                                   WHEN g.Status = 2 THEN l.FobCostBase
                                   WHEN l.ContainerLineId IS NOT NULL THEN COALESCE(ci.Fob, op.Price)
                                   WHEN pid.Id IS NOT NULL AND pil.FobCostBase IS NOT NULL THEN pil.FobCostBase
                                   WHEN l.PoLineId IS NOT NULL THEN op.Price
                                   -- (79) an order-less invoice that does not change item costs: what the posting will take
                                   WHEN l.PoLineId IS NULL AND l.InvoiceLineId IS NOT NULL
                                       THEN COALESCE(l.ManualUnitCostBase, NULLIF(it.LastCost, 0), NULLIF(it.AverageCost, 0), pil.UnitCostBase)
                                   ELSE l.ManualUnitCostBase END,
                        Charges = CASE WHEN g.Status = 3 THEN NULL
                                       WHEN g.Status = 2 AND l.ContainerLineId IS NOT NULL
                                           THEN cl.ChargesBase / NULLIF(cl.ReceivedQuantityBase, 0)
                                       WHEN g.Status = 2 THEN l.ChargesBase
                                       WHEN l.ContainerLineId IS NOT NULL THEN cl.ChargesBase / NULLIF(cl.QuantityBase, 0)
                                       WHEN pid.Id IS NOT NULL AND pil.FobCostBase IS NOT NULL
                                           THEN ISNULL(pil.AllocatedChargesBase, 0) / NULLIF(pil.QuantityBase, 0)
                                       ELSE CAST(0 AS DECIMAL(18,6)) END) y
    CROSS APPLY (SELECT Unit = CASE WHEN g.Status = 3 THEN l.CostAtReceiptBase
                                    WHEN g.Status = 2 AND l.ContainerLineId IS NOT NULL THEN COALESCE(cl.LandedCostBase, l.CostAtReceiptBase)
                                    WHEN g.Status = 2 THEN COALESCE(l.UnitCostBase, l.CostAtReceiptBase)
                                    ELSE y.Fob + ISNULL(y.Charges, 0) END) z
    WHERE l.GoodsReceiptId = @GoodsReceiptId;

GO

