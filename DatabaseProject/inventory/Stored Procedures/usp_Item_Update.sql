CREATE   PROCEDURE inventory.usp_Item_Update
    @Id                 INT,
    @ItemCode           NVARCHAR(30),
    @ItemName           NVARCHAR(200),
    @BrandId            INT,
    @Model              NVARCHAR(100)  = NULL,
    @ItemFamilyId       INT,
    @CountryOfOrigin    NVARCHAR(2),
    @DefaultWarehouseId INT,
    @Description        NVARCHAR(1000) = NULL,
    @WarrantyMonths     INT            = NULL,
    @MinQuantity        INT            = 0,
    @MaxQuantity        INT            = NULL,
    @IsBivac            BIT            = 0,
    @IsActive           BIT            = 1,
    @RowVersion         BINARY(8)      = NULL,
    @UserId             INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @ItemCode        = LTRIM(RTRIM(@ItemCode));
    SET @ItemName        = LTRIM(RTRIM(@ItemName));
    SET @Model           = NULLIF(LTRIM(RTRIM(@Model)), N'');
    SET @CountryOfOrigin = UPPER(LTRIM(RTRIM(@CountryOfOrigin)));
    SET @Description     = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @MinQuantity     = ISNULL(@MinQuantity, 0);
    SET @IsBivac         = ISNULL(@IsBivac, 0);
    SET @IsActive        = ISNULL(@IsActive, 1);

    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id)
        THROW 56006, 'Item not found.', 1;
    IF @ItemCode IS NULL OR @ItemCode = N'' THROW 56000, 'Item Code is required.', 1;
    IF @ItemName IS NULL OR @ItemName = N'' THROW 56000, 'Item Name is required.', 1;
    IF @CountryOfOrigin IS NULL OR LEN(@CountryOfOrigin) <> 2 OR @CountryOfOrigin LIKE N'%[^A-Z]%'
        THROW 56000, 'Country of Origin is required (2-letter ISO code).', 1;
    IF @WarrantyMonths IS NOT NULL AND @WarrantyMonths < 0 THROW 56000, 'Warranty cannot be negative.', 1;
    IF @MinQuantity < 0 THROW 56000, 'Minimum Quantity cannot be negative.', 1;
    IF @MaxQuantity IS NOT NULL AND @MaxQuantity < @MinQuantity
        THROW 56000, 'Minimum Quantity cannot exceed Maximum Quantity.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Brands WHERE Id = @BrandId AND IsActive = 1)
        THROW 56008, 'Brand not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ItemFamilies WHERE Id = @ItemFamilyId AND IsActive = 1)
        THROW 56008, 'Item Family not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsActive = 1)
        THROW 56008, 'Default Warehouse not found or inactive.', 1;

    IF EXISTS (SELECT 1 FROM inventory.Items WHERE ItemCode = @ItemCode AND Id <> @Id)
        THROW 56001, 'An item with this Item Code already exists.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 56004, 'This item was modified by another user. Reload the page and try again.', 1;

    UPDATE inventory.Items
    SET ItemCode = @ItemCode, ItemName = @ItemName, BrandId = @BrandId, Model = @Model,
        ItemFamilyId = @ItemFamilyId, CountryOfOrigin = @CountryOfOrigin,
        DefaultWarehouseId = @DefaultWarehouseId, Description = @Description,
        WarrantyMonths = @WarrantyMonths, MinQuantity = @MinQuantity, MaxQuantity = @MaxQuantity,
        IsBivac = @IsBivac, IsActive = @IsActive,
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END