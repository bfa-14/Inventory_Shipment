/* ================================================================== 3. The one rule: an invoice that does not change item costs */

-- Re-created (79) from the body of script 64. (79) The pieces matched to an invoice whose AffectsCost is 0 cost as
-- if they were unmatched: the order price (a container line keeps its container's charges, which never came from an
-- invoice). MatchedBase still counts every match (the post confirmation's "received, not invoiced", the counters);
-- CostMatchedBase counts those that price. A receipt line made from an order-less invoice of that kind keeps the cost
-- its receipt gave it. CostSource says where the target really comes from.
CREATE   FUNCTION purchase.fn_GoodsReceiptLine_TargetCost (@GoodsReceiptId INT)
RETURNS TABLE
AS
RETURN
    SELECT GoodsReceiptId      = g.Id,
           GoodsReceiptLineId  = gl.Id,
           gl.LineNumber, gl.ItemId, gl.WarehouseId, gl.SupplierId, gl.PoLineId, gl.InvoiceLineId, gl.ContainerLineId,
           ContainerId         = cl.ContainerId,
           IsContainerLine     = CAST(CASE WHEN gl.ContainerLineId IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           ReceivedBase        = gl.QuantityBase,
           MatchedBase         = m.Qty,
           CostMatchedBase     = m.CostQty,     -- (79) of them, the pieces matched to invoices that change item costs
           NetReceivedBase     = CAST(gl.QuantityBase - m.Returned AS DECIMAL(18,6)),
           BaseFobBase         = b.Fob,
           BaseChargesBase     = b.Charges,
           TargetFobBase       = t.Fob,
           TargetChargesBase   = t.Charges,
           TargetUnitCostBase  = CAST(t.Fob + t.Charges AS DECIMAL(18,6)),
           CurrentFobBase      = CASE WHEN gl.ContainerLineId IS NOT NULL THEN cl.FobCostBase ELSE gl.FobCostBase END,
           CurrentChargesBase  = CASE WHEN gl.ContainerLineId IS NOT NULL THEN CAST(cl.ChargesBase / gl.QuantityBase AS DECIMAL(18,6))
                                      ELSE gl.ChargesBase END,
           CurrentUnitCostBase = CASE WHEN gl.ContainerLineId IS NOT NULL THEN cl.LandedCostBase ELSE gl.UnitCostBase END,
           CostSource          = CAST(CASE WHEN m.CostQty >= gl.QuantityBase THEN N'Invoice'
                                           WHEN gl.PoLineId IS NULL AND gl.InvoiceLineId IS NOT NULL AND ISNULL(ild.AffectsCost, 1) = 1 THEN N'Invoice'
                                           WHEN m.CostQty > 0 THEN N'Mixed'
                                           WHEN gl.PoLineId IS NOT NULL THEN N'Order'
                                           ELSE N'Manual' END AS NVARCHAR(10))
    FROM purchase.GoodsReceipts g
    INNER JOIN purchase.GoodsReceiptLines gl      ON gl.GoodsReceiptId = g.Id AND gl.QuantityBase > 0
    LEFT  JOIN logistics.ContainerLines cl        ON cl.Id = gl.ContainerLineId
    LEFT  JOIN purchase.PurchaseDocumentLines pol ON pol.Id = gl.PoLineId
    LEFT  JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId
    LEFT  JOIN purchase.PurchaseDocumentLines il  ON il.Id = gl.InvoiceLineId
    LEFT  JOIN purchase.PurchaseDocuments ild     ON ild.Id = il.DocumentId
    CROSS APPLY (SELECT Qty      = ISNULL(SUM(x.QuantityBase), 0),
                        -- (79) only an invoice that changes item costs prices its pieces (AffectsCost, captured when
                        --      it was posted); the others' pieces cost as if unmatched, below
                        CostQty  = ISNULL(SUM(CASE WHEN pd.AffectsCost = 1 THEN x.QuantityBase ELSE 0 END), 0),
                        Fob      = ISNULL(SUM(CASE WHEN pd.AffectsCost = 1
                                                   THEN x.QuantityBase * COALESCE(p.FobCostBase, p.LineTotal / pd.ExchangeRate / p.QuantityBase) ELSE 0 END), 0),
                        Charges  = ISNULL(SUM(CASE WHEN pd.AffectsCost = 1 THEN x.QuantityBase * p.AllocatedChargesBase / p.QuantityBase ELSE 0 END), 0),
                        Returned = ISNULL(SUM(CAST(x.QuantityBase AS DECIMAL(18,6))
                                              * CASE WHEN p.ReturnedQuantityBase < p.ReceivedQuantityBase THEN p.ReturnedQuantityBase
                                                     ELSE p.ReceivedQuantityBase END
                                              / NULLIF(p.ReceivedQuantityBase, 0)), 0)
                 FROM purchase.GoodsReceiptInvoiceMatches x
                 INNER JOIN purchase.PurchaseDocumentLines p ON p.Id = x.InvoiceLineId
                 INNER JOIN purchase.PurchaseDocuments pd    ON pd.Id = p.DocumentId
                 WHERE x.GoodsReceiptLineId = gl.Id) m
    CROSS APPLY (SELECT Fob = CAST(CASE WHEN gl.PoLineId IS NOT NULL
                                        THEN COALESCE(gl.PoFobBase, pol.LineTotal / po.ExchangeRate / NULLIF(pol.QuantityBase, 0), 0)
                                        WHEN gl.InvoiceLineId IS NULL THEN ISNULL(gl.ManualUnitCostBase, 0)
                                        -- (79) an invoice without an order that does not change item costs: the cost
                                        --      the receipt gave it (usp_GoodsReceipt_Post: typed, else the item's)
                                        WHEN ild.AffectsCost = 0 THEN COALESCE(gl.ManualUnitCostBase, gl.CostAtReceiptBase, 0)
                                        ELSE COALESCE(gl.CostAtReceiptBase, il.UnitCostBase, 0) END AS DECIMAL(18,6)),
                        Charges = CAST(0 AS DECIMAL(18,6))) b
    CROSS APPLY (SELECT Fob     = CAST((m.Fob + CASE WHEN gl.ContainerLineId IS NOT NULL THEN m.Charges ELSE 0 END
                                        + (gl.QuantityBase - m.CostQty) * b.Fob) / gl.QuantityBase AS DECIMAL(18,6)),
                        Charges = CAST(CASE WHEN gl.ContainerLineId IS NOT NULL THEN ISNULL(cl.ChargesBase, 0) / gl.QuantityBase
                                            ELSE (m.Charges + (gl.QuantityBase - m.CostQty) * b.Charges) / gl.QuantityBase END AS DECIMAL(18,6))) t
    WHERE g.Id = @GoodsReceiptId AND g.Status = 2;

GO

