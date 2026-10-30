/* ================================================================== 3. The lead time of the history, and the one a shortage uses */

-- (98) One row per item (all items when @ItemId is NULL) that had goods received from a purchase order in the last 12
-- months: the time from the order's approval (PostedAtUtc) to the receipt's posting, weighted by the pieces received.
CREATE   FUNCTION inventory.fn_Item_LeadTimeHistory (@ItemId INT)
RETURNS TABLE
AS
RETURN
SELECT l.ItemId,
       Months = CAST(CASE WHEN SUM(CAST(DATEDIFF(DAY, po.PostedAtUtc, g.PostedAtUtc) AS DECIMAL(18,2)) * l.QuantityBase) / SUM(l.QuantityBase) / 30.0 < 0.1 THEN 0.1
                          ELSE ROUND(SUM(CAST(DATEDIFF(DAY, po.PostedAtUtc, g.PostedAtUtc) AS DECIMAL(18,2)) * l.QuantityBase) / SUM(l.QuantityBase) / 30.0, 1) END
                     AS DECIMAL(5,1)),
       Receipts = COUNT(DISTINCT g.Id)
FROM purchase.GoodsReceiptLines l
INNER JOIN purchase.GoodsReceipts g          ON g.Id = l.GoodsReceiptId AND g.Status = 2
                                            AND g.PostedAtUtc >= DATEADD(MONTH, -12, SYSUTCDATETIME())
INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PoLineId
INNER JOIN purchase.PurchaseDocuments po     ON po.Id = pl.DocumentId AND po.PostedAtUtc IS NOT NULL AND po.PostedAtUtc <= g.PostedAtUtc
WHERE l.QuantityBase > 0
  AND (@ItemId IS NULL OR l.ItemId = @ItemId)
GROUP BY l.ItemId;

GO

