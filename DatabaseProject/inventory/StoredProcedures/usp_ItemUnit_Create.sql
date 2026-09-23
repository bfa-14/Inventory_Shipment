/* ------------------------------------------------------------------ Item unit procedures */

CREATE   PROCEDURE inventory.usp_ItemUnit_Create
    @ItemId         INT,
    @UnitTypeId     INT,
    @PackingFormula INT,
    @SkuCode        NVARCHAR(50),
    @Barcode        NVARCHAR(50) = NULL,
    @IsSalesUnit    BIT          = 0,
    @IsPurchaseUnit BIT          = 0,
    @IsBaseUnit     BIT          = 0,
    @UserId         INT          = NULL,
    @NewId          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SkuCode = LTRIM(RTRIM(@SkuCode));
    SET @Barcode = NULLIF(LTRIM(RTRIM(@Barcode)), N'');
    SET @IsSalesUnit = ISNULL(@IsSalesUnit, 0);
    SET @IsPurchaseUnit = ISNULL(@IsPurchaseUnit, 0);
    SET @IsBaseUnit = ISNULL(@IsBaseUnit, 0);

    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @ItemId)
        THROW 56006, 'Item not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE Id = @UnitTypeId AND IsActive = 1)
        THROW 56008, 'Unit Type not found or inactive.', 1;
    IF @SkuCode IS NULL OR @SkuCode = N'' THROW 56000, 'SKU Code is required.', 1;
    IF @PackingFormula IS NULL OR @PackingFormula < 1
        THROW 56000, 'Packing Formula must be a whole number of at least 1.', 1;

    DECLARE @HasBase BIT = CASE WHEN EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE ItemId = @ItemId AND IsBaseUnit = 1) THEN 1 ELSE 0 END;

    IF @HasBase = 0 AND @IsBaseUnit = 0
        THROW 56005, 'The first unit of an item must be the Base Unit.', 1;
    IF @HasBase = 1 AND @IsBaseUnit = 1
        THROW 56005, 'This item already has a Base Unit. Edit the existing units to change which one is the base.', 1;
    IF @IsBaseUnit = 1 AND @PackingFormula <> 1
        THROW 56005, 'The Base Unit must have a Packing Formula of 1.', 1;

    IF EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE ItemId = @ItemId AND UnitTypeId = @UnitTypeId)
        THROW 56000, 'This item already has a unit of this Unit Type.', 1;
    IF EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE ItemId = @ItemId AND SkuCode = @SkuCode)
        THROW 56007, 'This SKU Code is already used by another unit of this item.', 1;
    IF @Barcode IS NOT NULL AND EXISTS (SELECT 1 FROM inventory.ItemUnits WHERE Barcode = @Barcode)
        THROW 56002, 'This Barcode is already used by another unit in the system.', 1;

    INSERT INTO inventory.ItemUnits (ItemId, UnitTypeId, PackingFormula, SkuCode, Barcode,
                                     IsSalesUnit, IsPurchaseUnit, IsBaseUnit, CreatedBy)
    VALUES (@ItemId, @UnitTypeId, @PackingFormula, @SkuCode, @Barcode,
            @IsSalesUnit, @IsPurchaseUnit, @IsBaseUnit, @UserId);

    SET @NewId = SCOPE_IDENTITY();
END

GO

