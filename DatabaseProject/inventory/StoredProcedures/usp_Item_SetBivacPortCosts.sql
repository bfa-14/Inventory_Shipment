CREATE   PROCEDURE inventory.usp_Item_SetBivacPortCosts
    @ItemId INT,
    @Costs  inventory.tvp_ItemPortCost READONLY,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @IsBivac BIT = (SELECT IsBivac FROM inventory.Items WHERE Id = @ItemId);
    IF @IsBivac IS NULL THROW 56006, 'Item not found.', 1;
    IF @IsBivac = 0 AND EXISTS (SELECT 1 FROM @Costs)
        THROW 56000, 'Only a BIVAC item has a cost per port: tick BIVAC Item and save the item first.', 1;
    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = CASE WHEN p.Id IS NULL THEN N'A port was not found: reload the page and try again.'
                               WHEN x.CostBase IS NULL THEN p.PortName + N': type the cost, or remove the port.'
                               ELSE p.PortName + N': the cost cannot be negative.' END
    FROM @Costs x LEFT JOIN masterdata.Ports p ON p.Id = x.PortId
    WHERE p.Id IS NULL OR x.CostBase IS NULL OR x.CostBase < 0;
    IF @Msg IS NOT NULL THROW 56000, @Msg, 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE pc FROM inventory.ItemBivacPortCosts pc
        WHERE pc.ItemId = @ItemId AND NOT EXISTS (SELECT 1 FROM @Costs x WHERE x.PortId = pc.PortId);
        UPDATE pc SET CostBase = x.CostBase, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM inventory.ItemBivacPortCosts pc INNER JOIN @Costs x ON x.PortId = pc.PortId
        WHERE pc.ItemId = @ItemId AND pc.CostBase <> x.CostBase;
        INSERT INTO inventory.ItemBivacPortCosts (ItemId, PortId, CostBase, UpdatedBy)
        SELECT @ItemId, x.PortId, x.CostBase, @UserId FROM @Costs x
        WHERE NOT EXISTS (SELECT 1 FROM inventory.ItemBivacPortCosts pc WHERE pc.ItemId = @ItemId AND pc.PortId = x.PortId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
    EXEC inventory.usp_Item_BivacPortCosts_Get @ItemId;
END

GO

