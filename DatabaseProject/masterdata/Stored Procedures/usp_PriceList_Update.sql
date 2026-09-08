CREATE   PROCEDURE masterdata.usp_PriceList_Update
    @Id            INT,
    @PriceListCode NVARCHAR(20),
    @PriceListName NVARCHAR(100),
    @CurrencyId    INT,
    @Description   NVARCHAR(500) = NULL,
    @IsActive      BIT           = 1,
    @RowVersion    BINARY(8)     = NULL,
    @UserId        INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @PriceListCode = LTRIM(RTRIM(@PriceListCode));
    SET @PriceListName = LTRIM(RTRIM(@PriceListName));
    SET @Description   = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @IsActive      = ISNULL(@IsActive, 1);

    IF NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @Id)
        THROW 58006, 'Price list not found.', 1;
    IF @PriceListCode IS NULL OR @PriceListCode = N'' THROW 58000, 'Price List Code is required.', 1;
    IF @PriceListName IS NULL OR @PriceListName = N'' THROW 58000, 'Price List Name is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 58008, 'Currency not found or inactive.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE PriceListCode = @PriceListCode AND Id <> @Id)
        THROW 58001, 'A price list with this code already exists.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE PriceListName = @PriceListName AND Id <> @Id)
        THROW 58001, 'A price list with this name already exists.', 1;

    -- The currency is locked once prices exist (all its prices are expressed in it).
    IF EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @Id AND CurrencyId <> @CurrencyId)
       AND EXISTS (SELECT 1 FROM masterdata.UnitPrices WHERE PriceListId = @Id)
        THROW 58009, 'The currency cannot be changed because this price list already contains prices. Create a new price list instead.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 58004, 'This price list was modified by another user. Reload the page and try again.', 1;

    UPDATE masterdata.PriceLists
    SET PriceListCode = @PriceListCode, PriceListName = @PriceListName, CurrencyId = @CurrencyId,
        Description = @Description, IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END