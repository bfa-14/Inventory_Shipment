/* ================================================================== 8. The container page's estimate follows the cost rule */

-- ONE ROW: THE FOB PER UNIT OF A CONTAINER LINE, as the container page shows it ("Real cost per item", the loaded items).
-- Once the goods are received it is the container line's own value (final: frozen by an offload of before, set by the
-- goods receipt and moved by the invoices since). Before, it is the ESTIMATE OF WHAT ITS GOODS RECEIPT WILL GIVE IT: the
-- cost rule of purchase.fn_GoodsReceiptLine_TargetCost (script 79) over the invoice pieces the receipt's matching
-- (purchase.usp_GoodsReceipt_Rematch, script 64) will give the line -
--   1. the pieces of the invoices linked to the container line (the matching's pass 1), posted or draft, as before (a
--      draft follows its type's "Affects item cost" as it is now, as the invoice's page says; a posted one what it was
--      posted with, PurchaseDocuments.AffectsCost);
--   2. then the order line's posted invoice pieces that no receipt takes by its own invoice or container line (not
--      linked to a container line, or left over by a container line received short), first in first out by posting,
--      over the order line's receipts in the order the matching takes them (its passes 2 and 3): its posted goods
--      receipts first, for the pieces their own invoice or container line does not cover (a draft invoice linked to that
--      line covers them once posted), then its container lines still on their way, in the order their containers were
--      created (containers usually arrive so), each for the pieces no invoice is linked to;
--   3. the pieces of invoices that change item costs at their price (with their own charges, as the receipt prices
--      them), every other piece - not invoiced, or invoiced by an invoice that does not change item costs - at the order
--      price.
-- It stays an estimate: another order of arrival, a later invoice or a receipt from the order moves it. The container's
-- charges are added by the caller, as before. FobSource: Received, Invoice (an invoice that changes item costs prices
-- pieces of it), Order. CostInvoicedBase: the pieces such invoices price.
CREATE   FUNCTION logistics.fn_ContainerLine_FobEstimate (@ContainerLineId INT)
RETURNS TABLE
AS
RETURN
WITH tl AS (    -- the line, its order line and order price; IsOpen = not received yet: only then is anything estimated
         SELECT cl.Id, cl.PoLineId, cl.QuantityBase, cl.FobCostBase, OrderPrice = op.Price,
                IsOpen = CAST(CASE WHEN cl.FobCostBase IS NULL AND cl.PoLineId IS NOT NULL THEN 1 ELSE 0 END AS BIT)
         FROM logistics.ContainerLines cl
         OUTER APPLY (SELECT Price = pol.LineTotal / pod.ExchangeRate / NULLIF(pol.QuantityBase, 0)
                      FROM purchase.PurchaseDocumentLines pol
                      INNER JOIN purchase.PurchaseDocuments pod ON pod.Id = pol.DocumentId
                      WHERE pol.Id = cl.PoLineId) op
         WHERE cl.Id = @ContainerLineId),
     -- 1. the invoices linked to the line: the pieces of those that change item costs, and their value
     lk AS (SELECT CostQty   = SUM(CASE WHEN ac.AffectsCost = 1 THEN pil.QuantityBase ELSE 0 END),
                   CostValue = SUM(CASE WHEN ac.AffectsCost = 1 THEN pil.LineTotal / d.ExchangeRate ELSE 0 END)
            FROM purchase.PurchaseDocumentLines pil
            INNER JOIN purchase.PurchaseDocuments d ON d.Id = pil.DocumentId
            INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
            CROSS APPLY (SELECT AffectsCost = CASE WHEN d.Status = 1 THEN ISNULL(dt.AffectsItemCost, 1) ELSE d.AffectsCost END) ac
            WHERE pil.ContainerLineId = @ContainerLineId AND d.Status <> 3),
     -- 2a. the order line's receipts in the order the matching takes them, each for the pieces nothing of its own covers
     --     (E = their running total): its posted goods receipts by posting, then its container lines still on their way
     --     (their containers Draft to Cleared) by container
     sl AS (SELECT r.Bucket, r.ContainerLineId, r.Demand,
                   E = SUM(r.Demand) OVER (ORDER BY r.Bucket, r.SortT, r.SortC, r.SortId ROWS UNBOUNDED PRECEDING)
            FROM (SELECT Bucket = 0, SortT = ISNULL(g.PostedAtUtc, g.CreatedAtUtc), SortC = 0, SortId = gl.Id,
                         ContainerLineId = gl.ContainerLineId,
                         Demand = gl.QuantityBase - ISNULL(own.Qty, 0) - ISNULL(dr.Qty, 0)
                  FROM tl
                  INNER JOIN purchase.GoodsReceiptLines gl ON gl.PoLineId = tl.PoLineId AND gl.PoLineId IS NOT NULL
                  INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId AND g.Status = 2
                  -- what its own invoice line or container line gave it (the matching's passes 0 and 1)
                  OUTER APPLY (SELECT Qty = SUM(x.QuantityBase)
                               FROM purchase.GoodsReceiptInvoiceMatches x
                               INNER JOIN purchase.PurchaseDocumentLines p ON p.Id = x.InvoiceLineId
                               WHERE x.GoodsReceiptLineId = gl.Id
                                 AND (p.Id = gl.InvoiceLineId OR p.ContainerLineId = gl.ContainerLineId)) own
                  -- a draft invoice linked to its container line: matched there once it is posted
                  OUTER APPLY (SELECT Qty = SUM(p.QuantityBase)
                               FROM purchase.PurchaseDocumentLines p
                               INNER JOIN purchase.PurchaseDocuments d ON d.Id = p.DocumentId AND d.Status = 1
                               WHERE gl.ContainerLineId IS NOT NULL AND p.ContainerLineId = gl.ContainerLineId) dr
                  WHERE tl.IsOpen = 1 AND gl.QuantityBase > 0
                  UNION ALL
                  SELECT 1, NULL, o.ContainerId, o.Id, o.Id, o.QuantityBase - ISNULL(ol.Qty, 0)
                  FROM tl
                  INNER JOIN logistics.ContainerLines o ON o.PoLineId = tl.PoLineId AND o.FobCostBase IS NULL
                  INNER JOIN logistics.Containers oc    ON oc.Id = o.ContainerId AND oc.Status BETWEEN 1 AND 5
                  -- the pieces linked to an invoice (posted or draft): its own container line's, matched there
                  OUTER APPLY (SELECT Qty = SUM(p.QuantityBase)
                               FROM purchase.PurchaseDocumentLines p
                               INNER JOIN purchase.PurchaseDocuments d ON d.Id = p.DocumentId AND d.Status <> 3
                               WHERE p.ContainerLineId = o.Id) ol
                  WHERE tl.IsOpen = 1
                    AND NOT EXISTS (SELECT 1
                                    FROM purchase.GoodsReceiptLines rl
                                    INNER JOIN purchase.GoodsReceipts rg ON rg.Id = rl.GoodsReceiptId AND rg.Status = 2
                                    WHERE rl.ContainerLineId = o.Id)) r
            WHERE r.Demand > 0),
     -- 2b. the order line's posted invoice pieces no receipt takes by its own invoice or container line, by posting (E =
     --     their running total); a line linked to a container line only once that line is received by a goods receipt
     --     (until then its pieces wait for it), and never one the matching leaves out (a local invoice of before goods
     --     receipts, a container offloaded before them)
     sp AS (SELECT u.Free, u.IsCost, u.Price,
                   E = SUM(u.Free) OVER (ORDER BY u.T, u.Id ROWS UNBOUNDED PRECEDING)
            FROM (SELECT p.Id, T = ISNULL(d.PostedAtUtc, d.CreatedAtUtc),
                         Free = p.QuantityBase - ISNULL(m.Qty, 0),
                         IsCost = CAST(CASE WHEN d.AffectsCost = 1 THEN 1 ELSE 0 END AS BIT),
                         Price = COALESCE(p.FobCostBase, p.LineTotal / d.ExchangeRate / NULLIF(p.QuantityBase, 0))
                                 + ISNULL(p.AllocatedChargesBase, 0) / NULLIF(p.QuantityBase, 0)
                  FROM tl
                  INNER JOIN purchase.PurchaseDocumentLines p ON p.SourceLineId = tl.PoLineId AND p.SourceLineId IS NOT NULL
                  INNER JOIN purchase.PurchaseDocuments d     ON d.Id = p.DocumentId AND d.Status IN (2, 4)
                  INNER JOIN inventory.DocumentTypes dt       ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
                  -- what its own receipts took (passes 0 and 1): a receipt made from it, or its container line's
                  OUTER APPLY (SELECT Qty = SUM(x.QuantityBase)
                               FROM purchase.GoodsReceiptInvoiceMatches x
                               INNER JOIN purchase.GoodsReceiptLines rl ON rl.Id = x.GoodsReceiptLineId
                               WHERE x.InvoiceLineId = p.Id
                                 AND (rl.InvoiceLineId = p.Id OR rl.ContainerLineId = p.ContainerLineId)) m
                  WHERE tl.IsOpen = 1
                    AND CASE WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 THEN 0 ELSE 1 END = 1
                    AND (p.ContainerLineId IS NULL
                         OR EXISTS (SELECT 1
                                    FROM purchase.GoodsReceiptLines rl
                                    INNER JOIN purchase.GoodsReceipts rg ON rg.Id = rl.GoodsReceiptId AND rg.Status = 2
                                    WHERE rl.ContainerLineId = p.ContainerLineId))) u
            WHERE u.Free > 0),
     -- 2c. what the line's own place in 2a takes of 2b: the overlap of the two running totals, as the matching pairs them
     q AS (SELECT CostQty   = SUM(CASE WHEN sp.IsCost = 1 THEN ov.Qty ELSE 0 END),
                  CostValue = SUM(CASE WHEN sp.IsCost = 1 THEN ov.Qty * sp.Price ELSE 0 END)
           FROM sl
           INNER JOIN sp ON sl.E - sl.Demand < sp.E AND sp.E - sp.Free < sl.E
           CROSS APPLY (SELECT Qty = CASE WHEN sl.E < sp.E THEN sl.E ELSE sp.E END
                                     - CASE WHEN sl.E - sl.Demand > sp.E - sp.Free THEN sl.E - sl.Demand ELSE sp.E - sp.Free END) ov
           WHERE sl.Bucket = 1 AND sl.ContainerLineId = @ContainerLineId)
SELECT ContainerLineId  = tl.Id,
       OrderPriceBase   = tl.OrderPrice,
       CostInvoicedBase = c.Qty,
       EstimatedFobBase = es.Fob,
       UnitFobBase      = COALESCE(tl.FobCostBase, es.Fob),
       FobSource        = CAST(CASE WHEN tl.FobCostBase IS NOT NULL THEN N'Received'
                                    WHEN c.Qty > 0 THEN N'Invoice' ELSE N'Order' END AS NVARCHAR(10))
FROM tl
CROSS JOIN lk
CROSS JOIN q
-- 3. the pieces priced by invoices that change item costs, every other piece at the order price
CROSS APPLY (SELECT Qty = ISNULL(lk.CostQty, 0) + ISNULL(q.CostQty, 0), Value = ISNULL(lk.CostValue, 0) + ISNULL(q.CostValue, 0)) c
CROSS APPLY (SELECT Fob = CAST(CASE WHEN c.Qty = 0 THEN tl.OrderPrice
                                    ELSE (c.Value + CASE WHEN c.Qty < tl.QuantityBase THEN tl.QuantityBase - c.Qty ELSE 0 END
                                                    * COALESCE(tl.OrderPrice, c.Value / c.Qty))
                                         / CASE WHEN c.Qty < tl.QuantityBase THEN tl.QuantityBase ELSE c.Qty END END
                               AS DECIMAL(18,6))) es;

GO

