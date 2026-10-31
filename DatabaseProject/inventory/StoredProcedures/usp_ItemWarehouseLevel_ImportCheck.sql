--      written. @UserId is read by script 92 (warehouse access).
-- Re-created (92) from the body of script 91: + a row in a warehouse the user may not use is an Error with the
-- sentence (W6, W17): the judgement goes into #j (the same 20 columns), the refused Valid / Warning rows become Error /
-- None, then the same 20 columns by row number. (SELECT ... INTO types Status / Action / Message from the function:
-- NVARCHAR(10), (10), (500); 'Error', 'None' and the sentence fit.)
CREATE   PROCEDURE inventory.usp_ItemWarehouseLevel_ImportCheck
    @Rows   inventory.tvp_ItemWarehouseLevelImport READONLY,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT j.RowNumber, j.Status, j.Action, j.Message, j.ItemInput, j.ItemId, j.ItemCode, j.ItemName, j.ItemIsActive,
           j.WarehouseInput, j.WarehouseId, j.WarehouseCode, j.WarehouseName, j.BranchCode,
           j.MinQuantityBase, j.MaxQuantityBase, j.IsRemove, j.HasLevel, j.CurrentMinBase, j.CurrentMaxBase
    INTO #j
    FROM inventory.fn_ItemWarehouseLevel_ImportJudge(@Rows) j;

    -- (92) the rows a restricted user may not import: Error, with the sentence (one call per warehouse)
    IF security.fn_User_IsUnrestricted(@UserId) = 0
    BEGIN
        DECLARE @Refused TABLE (WarehouseId INT NOT NULL PRIMARY KEY, Message NVARCHAR(400) NULL);
        INSERT INTO @Refused (WarehouseId, Message)
        SELECT d.WarehouseId, security.fn_User_WarehouseRefusal(@UserId, CAST(d.WarehouseId AS NVARCHAR(12)))
        FROM (SELECT DISTINCT WarehouseId FROM #j WHERE Status IN (N'Valid', N'Warning') AND WarehouseId IS NOT NULL) d;
        UPDATE j SET Status = N'Error', Action = N'None', Message = r.Message
        FROM #j j INNER JOIN @Refused r ON r.WarehouseId = j.WarehouseId
        WHERE j.Status IN (N'Valid', N'Warning') AND r.Message IS NOT NULL;
    END

    SELECT j.RowNumber, j.Status, j.Action, j.Message, j.ItemInput, j.ItemId, j.ItemCode, j.ItemName, j.ItemIsActive,
           j.WarehouseInput, j.WarehouseId, j.WarehouseCode, j.WarehouseName, j.BranchCode,
           j.MinQuantityBase, j.MaxQuantityBase, j.IsRemove, j.HasLevel, j.CurrentMinBase, j.CurrentMaxBase
    FROM #j j
    ORDER BY j.RowNumber;
END

GO

