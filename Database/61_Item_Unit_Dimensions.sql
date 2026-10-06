SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   61: Item unit dimensions and weight
   --------------------------------------------------------------------------------------------------
   Every unit of an item (the piece, the box, the pallet) can record its outside size and its weight:
   Length, Width and Height in centimetres and Weight in kilograms. All optional; a value that is
   entered must be greater than zero.

     inventory.ItemUnits             LengthCm, WidthCm, HeightCm (DECIMAL 10,2), WeightKg (DECIMAL 12,3)
     usp_ItemUnit_Create / _Update   take them (NULL = not recorded)
     usp_Item_Get / usp_ItemUnit_ListByItem   return them
   ================================================================================================== */

IF OBJECT_ID(N'inventory.ItemUnits', N'U') IS NULL
BEGIN
    RAISERROR ('The inventory scripts must run before script 61.', 16, 1);
    SET NOEXEC ON;
END
GO

IF COL_LENGTH(N'inventory.ItemUnits', N'LengthCm') IS NULL
    ALTER TABLE inventory.ItemUnits ADD
        LengthCm DECIMAL(10,2) NULL,
        WidthCm  DECIMAL(10,2) NULL,
        HeightCm DECIMAL(10,2) NULL,
        WeightKg DECIMAL(12,3) NULL;
GO

IF OBJECT_ID(N'inventory.CK_ItemUnits_Dimensions', N'C') IS NULL
    ALTER TABLE inventory.ItemUnits ADD CONSTRAINT CK_ItemUnits_Dimensions CHECK (
        (LengthCm IS NULL OR LengthCm > 0) AND (WidthCm IS NULL OR WidthCm > 0)
        AND (HeightCm IS NULL OR HeightCm > 0) AND (WeightKg IS NULL OR WeightKg > 0));
GO

CREATE OR ALTER PROCEDURE inventory.usp_ItemUnit_Create
    @ItemId         INT,
    @UnitTypeId     INT,
    @PackingFormula INT,
    @SkuCode        NVARCHAR(50),
    @Barcode        NVARCHAR(50) = NULL,
    @IsSalesUnit    BIT          = 0,
    @IsPurchaseUnit BIT          = 0,
    @IsBaseUnit     BIT          = 0,
    @UserId         INT          = NULL,
    @NewId          INT OUTPUT,
    /* (61) The unit's size and weight - one box, one pallet; NULL = not recorded. */
    @LengthCm       DECIMAL(10,2) = NULL,
    @WidthCm        DECIMAL(10,2) = NULL,
    @HeightCm       DECIMAL(10,2) = NULL,
    @WeightKg       DECIMAL(12,3) = NULL
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
    IF (@LengthCm IS NOT NULL AND @LengthCm <= 0) OR (@WidthCm IS NOT NULL AND @WidthCm <= 0) OR (@HeightCm IS NOT NULL AND @HeightCm <= 0)
        THROW 56000, 'Length, width and height must be greater than zero.', 1;
    IF @WeightKg IS NOT NULL AND @WeightKg <= 0 THROW 56000, 'Weight must be greater than zero.', 1;

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
                                     IsSalesUnit, IsPurchaseUnit, IsBaseUnit, LengthCm, WidthCm, HeightCm, WeightKg, CreatedBy)
    VALUES (@ItemId, @UnitTypeId, @PackingFormula, @SkuCode, @Barcode,
            @IsSalesUnit, @IsPurchaseUnit, @IsBaseUnit, @LengthCm, @WidthCm, @HeightCm, @WeightKg, @UserId);

    SET @NewId = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_ItemUnit_Update
    @Id             INT,
    @UnitTypeId     INT,
    @PackingFormula INT,
    @SkuCode        NVARCHAR(50),
    @Barcode        NVARCHAR(50) = NULL,
    @IsSalesUnit    BIT          = 0,
    @IsPurchaseUnit BIT          = 0,
    @IsBaseUnit     BIT          = 0,
    @RowVersion     BINARY(8)    = NULL,
    @UserId         INT          = NULL,
    /* (61) The unit's size and weight - one box, one pallet; NULL = not recorded. */
    @LengthCm       DECIMAL(10,2) = NULL,
    @WidthCm        DECIMAL(10,2) = NULL,
    @HeightCm       DECIMAL(10,2) = NULL,
    @WeightKg       DECIMAL(12,3) = NULL
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
    IF (@LengthCm IS NOT NULL AND @LengthCm <= 0) OR (@WidthCm IS NOT NULL AND @WidthCm <= 0) OR (@HeightCm IS NOT NULL AND @HeightCm <= 0)
        THROW 56000, 'Length, width and height must be greater than zero.', 1;
    IF @WeightKg IS NOT NULL AND @WeightKg <= 0 THROW 56000, 'Weight must be greater than zero.', 1;
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
            LengthCm = @LengthCm, WidthCm = @WidthCm, HeightCm = @HeightCm, WeightKg = @WeightKg,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_ItemUnit_ListByItem
    @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit, u.LengthCm, u.WidthCm, u.HeightCm, u.WeightKg
    FROM inventory.ItemUnits u
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
    WHERE u.ItemId = @ItemId
    ORDER BY u.IsBaseUnit DESC, u.PackingFormula, ut.UnitTypeName;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName, i.Description,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           OnHand = inventory.fn_StockOnHand(i.Id, NULL),
           FobCost = CAST(i.FobCost AS DECIMAL(18,2)),
           LastCost = CAST(i.LastCost AS DECIMAL(18,2)),
           AverageCost = CAST(i.AverageCost AS DECIMAL(18,2)),
           InventoryValue = CAST(inventory.fn_StockOnHand(i.Id, NULL) * i.AverageCost AS DECIMAL(18,2)),
           LastPurchaseCost = CAST(i.FobCost AS DECIMAL(18,2)),      -- kept for the current API mapping (= FOB)
           i.DefaultSupplierId, ds.PartyCode AS DefaultSupplierCode, ds.PartyName AS DefaultSupplierName, i.LeadTimeDays,
           PcPerContainer = cnt.PackingFormula,      -- from the item's Container unit
           PcPerContainerFromUnit = CAST(CASE WHEN cnt.PackingFormula IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           i.WeightKg, i.VolumeCbm, i.OilQtyPerUnit,
           i.LastSupplierId, ls.PartyName AS LastSupplierName, i.LastPurchaseAtUtc,
           i.CreatedAtUtc, i.CreatedBy, cu.FullName AS CreatedByName,
           i.UpdatedAtUtc, i.UpdatedBy, uu.FullName AS UpdatedByName, i.RowVersion
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b       ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w   ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN masterdata.Parties ds     ON ds.Id = i.DefaultSupplierId
    LEFT  JOIN masterdata.Parties ls     ON ls.Id = i.LastSupplierId
    LEFT  JOIN security.Users cu ON cu.Id = i.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = i.UpdatedBy
    OUTER APPLY
    (
        SELECT TOP (1) u.PackingFormula
        FROM inventory.ItemUnits u INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
        WHERE u.ItemId = i.Id AND t.IsContainer = 1
    ) cnt
    WHERE i.Id = @Id;

    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit, IsContainerUnit = ut.IsContainer,
           u.LengthCm, u.WidthCm, u.HeightCm, u.WeightKg, u.RowVersion
    FROM inventory.ItemUnits u
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
    WHERE u.ItemId = @Id
    ORDER BY u.IsBaseUnit DESC, u.PackingFormula, ut.UnitTypeName;

    SELECT fl.Id, fl.ItemId, fl.FileName, fl.ContentType, fl.SizeBytes, fl.IsItemImage, fl.CreatedAtUtc
    FROM inventory.ItemFiles fl
    WHERE fl.ItemId = @Id
    ORDER BY fl.IsItemImage DESC, fl.CreatedAtUtc DESC;
END
GO

PRINT 'Script 61 applied: item unit dimensions and weight.';
GO

SET NOEXEC OFF;
GO
