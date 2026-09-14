CREATE   PROCEDURE inventory.usp_Item_ApplyReceipts
    @Receipts   inventory.tvp_ItemReceipt READONLY,
    @SupplierId INT = NULL,      -- purchases: becomes the item's last supplier
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS
    (
        SELECT ItemId, Qty = SUM(QuantityBase), Cost = SUM(CAST(QuantityBase AS DECIMAL(18,6)) * UnitCostBase)
        FROM @Receipts WHERE QuantityBase > 0 GROUP BY ItemId
    )
    UPDATE i
    SET AverageCost = CASE WHEN oh.Q + a.Qty > 0 THEN (oh.Q * i.AverageCost + a.Cost) / (oh.Q + a.Qty) ELSE i.AverageCost END,
        LastCost = a.Cost / a.Qty,
        LastSupplierId = COALESCE(@SupplierId, i.LastSupplierId),
        LastPurchaseAtUtc = CASE WHEN @SupplierId IS NOT NULL THEN SYSUTCDATETIME() ELSE i.LastPurchaseAtUtc END
    FROM inventory.Items i
    INNER JOIN agg a ON a.ItemId = i.Id
    CROSS APPLY (SELECT Q = CAST(CASE WHEN inventory.fn_StockOnHand(i.Id, NULL) > 0 THEN inventory.fn_StockOnHand(i.Id, NULL) ELSE 0 END AS DECIMAL(18,6))) oh;
END