CREATE   PROCEDURE masterdata.usp_PriceList_Create
    @PriceListCode NVARCHAR(20),
    @PriceListName NVARCHAR(100),
    @CurrencyId    INT,
    @Description   NVARCHAR(500) = NULL,
    @IsActive      BIT           = 1,
    @UserId        INT           = NULL,
    @NewId         INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @PriceListCode = LTRIM(RTRIM(@PriceListCode));
    SET @PriceListName = LTRIM(RTRIM(@PriceListName));
    SET @Description   = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @IsActive      = ISNULL(@IsActive, 1);

    IF @PriceListCode IS NULL OR @PriceListCode = N'' THROW 58000, 'Price List Code is required.', 1;
    IF @PriceListName IS NULL OR @PriceListName = N'' THROW 58000, 'Price List Name is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 58008, 'Currency not found or inactive.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE PriceListCode = @PriceListCode)
        THROW 58001, 'A price list with this code already exists.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE PriceListName = @PriceListName)
        THROW 58001, 'A price list with this name already exists.', 1;

    INSERT INTO masterdata.PriceLists (PriceListCode, PriceListName, CurrencyId, Description, IsActive, CreatedBy)
    VALUES (@PriceListCode, @PriceListName, @CurrencyId, @Description, @IsActive, @UserId);

    SET @NewId = SCOPE_IDENTITY();
END

GO

