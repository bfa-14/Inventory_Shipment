/* (91) REMOVE ONE LEVEL (allowed on an inactive warehouse, L6): the row WITH (UPDLOCK, HOLDLOCK); gone 56006, changed
   since the page read it 56004; audit Removed; DELETE. @Source ItemCard | StockLevels (anything else: ItemCard). */
CREATE   PROCEDURE inventory.usp_ItemWarehouseLevel_Remove
    @ItemId      INT,
    @WarehouseId INT,
    @RowVersion  BINARY(8)    = NULL,
    @Source      NVARCHAR(20) = N'ItemCard',
    @UserId      INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Source IS NULL OR @Source NOT IN (N'ItemCard', N'StockLevels') SET @Source = N'ItemCard';

    DECLARE @Min INT, @Max INT, @Rv BINARY(8), @Msg NVARCHAR(400);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Min = lv.MinQuantityBase, @Max = lv.MaxQuantityBase, @Rv = lv.RowVersion
        FROM inventory.ItemWarehouseLevels lv WITH (UPDLOCK, HOLDLOCK)
        WHERE lv.ItemId = @ItemId AND lv.WarehouseId = @WarehouseId;

        IF @Rv IS NULL THROW 56006, 'This stock level no longer exists. Reload the page.', 1;

        IF @RowVersion IS NOT NULL AND @RowVersion <> @Rv
        BEGIN
            SET @Msg = N'The stock level of ' + ISNULL((SELECT ItemCode FROM inventory.Items WHERE Id = @ItemId), N'the item')
                     + N' at ' + ISNULL((SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId), N'the warehouse')
                     + N' was changed by another user. Reload and try again.';
            THROW 56004, @Msg, 1;
        END

        INSERT INTO inventory.ItemWarehouseLevelAudit (ItemId, WarehouseId, Action, OldMinBase, OldMaxBase, NewMinBase, NewMaxBase, Source, UserId)
        VALUES (@ItemId, @WarehouseId, N'Removed', @Min, @Max, NULL, NULL, @Source, @UserId);

        DELETE FROM inventory.ItemWarehouseLevels WHERE ItemId = @ItemId AND WarehouseId = @WarehouseId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

