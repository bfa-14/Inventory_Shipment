/* ================================================================== 20. The menu count */

-- THE DRAFT GOODS RECEIPTS, for the menu count (hidden at 0) and its tooltip: how many, how many made by a Delivery,
-- how many still without a warehouse, the oldest. Goods receipts are not limited by branch, so every viewer sees the
-- same count; @UserId is kept for when they are.
CREATE   PROCEDURE purchase.usp_GoodsReceipt_WaitingCount
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DraftCount            = COUNT(*),
           AutoDraftCount        = ISNULL(SUM(CASE WHEN g.IsAuto = 1 THEN 1 ELSE 0 END), 0),
           WithoutWarehouseCount = ISNULL(SUM(CASE WHEN g.SourceKind = N'Container' AND g.WarehouseId IS NULL THEN 1 ELSE 0 END), 0),
           OldestDraftDate       = MIN(g.DocumentDate),
           OldestCreatedAtUtc    = MIN(g.CreatedAtUtc)
    FROM purchase.GoodsReceipts g
    WHERE g.Status = 1;
END

GO

