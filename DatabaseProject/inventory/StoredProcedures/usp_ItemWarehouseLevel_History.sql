CREATE   PROCEDURE inventory.usp_ItemWarehouseLevel_History
    @ItemId      INT,
    @WarehouseId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.Id, a.AtUtc, a.Action, a.OldMinBase, a.OldMaxBase, a.NewMinBase, a.NewMaxBase, a.Source, a.FileName,
           UserName = u.FullName
    FROM inventory.ItemWarehouseLevelAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.ItemId = @ItemId AND a.WarehouseId = @WarehouseId
    ORDER BY a.AtUtc DESC, a.Id DESC;
END

GO

