--      written. @UserId is read by script 92 (warehouse access).
CREATE   PROCEDURE inventory.usp_ItemWarehouseLevel_ImportCheck
    @Rows   inventory.tvp_ItemWarehouseLevelImport READONLY,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT j.RowNumber, j.Status, j.Action, j.Message, j.ItemInput, j.ItemId, j.ItemCode, j.ItemName, j.ItemIsActive,
           j.WarehouseInput, j.WarehouseId, j.WarehouseCode, j.WarehouseName, j.BranchCode,
           j.MinQuantityBase, j.MaxQuantityBase, j.IsRemove, j.HasLevel, j.CurrentMinBase, j.CurrentMaxBase
    FROM inventory.fn_ItemWarehouseLevel_ImportJudge(@Rows) j
    ORDER BY j.RowNumber;
END

GO

