/* ================================================================== 10. Receipt lines: matching groups, target cost, current cost */

-- THE POSTED RECEIPT LINES OF THE GROUPS: an order line ('P', every container line of it included) or a supplier +
-- item ('S', goods without an order). The callers true up these lines after a rematch (leaving out the receipt that
-- is being posted, whose own cost is set directly).
CREATE   FUNCTION purchase.fn_GoodsReceipt_GroupLines (@Anchors purchase.tvp_GoodsReceiptAnchor READONLY)
RETURNS TABLE
AS
RETURN
    SELECT GoodsReceiptLineId = gl.Id, gl.GoodsReceiptId
    FROM purchase.GoodsReceiptLines gl
    INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId AND g.Status = 2
    WHERE EXISTS (SELECT 1 FROM @Anchors a
                  WHERE (a.Kind = 'P' AND a.PoLineId = gl.PoLineId)
                     OR (a.Kind = 'S' AND gl.PoLineId IS NULL AND a.SupplierId = gl.SupplierId AND a.ItemId = gl.ItemId));

GO

