CREATE   PROCEDURE inventory.usp_ItemUnit_Update
    @Id             INT,
    @UnitTypeId     INT,
    @PackingFormula INT,
    @SkuCode        NVARCHAR(50),
    @Barcode        NVARCHAR(50) = NULL,
    @IsSalesUnit    BIT          = 0,
    @IsPurchaseUnit BIT          = 0,
    @IsBaseUnit     BIT          = 0,
    @RowVersion     BINARY(8)    = NULL,
    @UserId         INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SkuCode = LTRIM(RTRIM(@SkuCode));
    SET @Barcode = NULLIF(LTRIM(RTRIM(@Barcode)), N'');
    SET @IsSalesUnit = ISNULL(@IsSalesUnit, 0);
    SET @IsPurchaseUnit = ISNULL(@IsPurchaseUnit, 0);
    SET @IsBaseUnit = ISNULL(@IsBaseUnit, 0);

    DECLARE @ItemId INT, @WasBase BIT;
    SELECT @ItemId = ItemId, @WasBase = IsBaseUnit FROM inventory.ItemUnits WHERE Id = @Id;

    IF @ItemId IS NULL
        THROW 56006, 'Item unit not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE Id = @UnitTypeId AND IsActive = 1)
        THROW 56008, 'Unit Type not found or inactive.', 1;
    IF @SkuCode IS NULL OR @SkuCode = N'' THROW 56000, 'SKU Code is required.', 1;
    IF @PackingFormula IS NULL OR @PackingFormula < 1
        THROW 56000, 'Packing Formula must be a whole number of at least 1.', 1;
    IF @WasBase = 1 AND @IsBaseUnit = 0
        THROW 56005, 'Every item needs a Base Unit. Mark another unit as the base instead (that switches automatically).', 1;
    IF @IsBaseUnit = 1 AND @PackingFormula <> 1
        THROW 56005, 'The Base Unit must have a Packing Formula of 1.', 1;

    IF EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE ItemId = @ItemId AND UnitTypeId = @UnitTypeId AND Id <> @Id)
        THROW 56000, 'This item already has a unit of this Unit Type.', 1;
    IF EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE ItemId = @ItemId AND SkuCode = @SkuCode AND Id <> @Id)
        THROW 56007, 'This SKU Code is already used by another unit of this item.', 1;
    IF @Barcode IS NOT NULL AND EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE Barcode = @Barcode AND Id <> @Id)
        THROW 56002, 'This Barcode is already used by another unit in the system.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 56004, 'This unit was modified by another user. Reload the page and try again.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Becoming the base demotes the current base (single-base invariant).
        IF @IsBaseUnit = 1 AND @WasBase = 0
        BEGIN
            UPDATE inventory.ItemUnits
            SET IsBaseUnit = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE ItemId = @ItemId AND IsBaseUnit = 1;
        END

        UPDATE inventory.ItemUnits
        SET UnitTypeId = @UnitTypeId, PackingFormula = @PackingFormula, SkuCode = @SkuCode, Barcode = @Barcode,
            IsSalesUnit = @IsSalesUnit, IsPurchaseUnit = @IsPurchaseUnit, IsBaseUnit = @IsBaseUnit,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END