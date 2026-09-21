CREATE   PROCEDURE inventory.usp_Item_ApplyReceipts
    @Receipts       inventory.tvp_ItemReceipt READONLY,
    @SupplierId     INT = NULL,
    @UserId         INT = NULL,
    @UpdateLastCost BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS
    (
        SELECT ItemId,
               Qty    = SUM(QuantityBase),
               Cost   = SUM(CAST(QuantityBase AS DECIMAL(18,6)) * UnitCostBase),
               FobQty = SUM(CASE WHEN FobCostBase IS NOT NULL THEN QuantityBase ELSE 0 END),
               Fob    = SUM(CASE WHEN FobCostBase IS NOT NULL THEN CAST(QuantityBase AS DECIMAL(18,6)) * FobCostBase ELSE 0 END)
        FROM @Receipts WHERE QuantityBase > 0 GROUP BY ItemId
    )
    UPDATE i
    SET AverageCost       = CASE WHEN oh.Q + a.Qty > 0 THEN (oh.Q * i.AverageCost + a.Cost) / (oh.Q + a.Qty) ELSE i.AverageCost END,
        LastCost          = CASE WHEN @UpdateLastCost = 1 THEN a.Cost / a.Qty ELSE i.LastCost END,
        FobCost           = CASE WHEN @UpdateLastCost = 1 AND a.FobQty > 0 THEN a.Fob / a.FobQty ELSE i.FobCost END,
        LastSupplierId    = CASE WHEN @UpdateLastCost = 1 THEN COALESCE(@SupplierId, i.LastSupplierId) ELSE i.LastSupplierId END,
        LastPurchaseAtUtc = CASE WHEN @UpdateLastCost = 1 AND @SupplierId IS NOT NULL THEN SYSUTCDATETIME() ELSE i.LastPurchaseAtUtc END
    FROM inventory.Items i
    INNER JOIN agg a ON a.ItemId = i.Id
    CROSS APPLY (SELECT Q = CAST(CASE WHEN inventory.fn_StockOnHand(i.Id, NULL) > 0 THEN inventory.fn_StockOnHand(i.Id, NULL) ELSE 0 END AS DECIMAL(18,6))) oh;
END