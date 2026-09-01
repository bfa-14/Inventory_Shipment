CREATE   PROCEDURE masterdata.usp_ExchangeRate_Create
    @CurrencyId INT,
    @RateType   TINYINT,               -- 1 Official | 2 NonOfficial | 3 Market
    @RateDate   DATE,
    @Rate       DECIMAL(18,6),
    @Notes      NVARCHAR(300) = NULL,
    @UserId     INT           = NULL,
    @NewId      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    IF @CurrencyId IS NULL
        THROW 53000, 'Currency is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId)
        THROW 53006, 'Currency not found.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1)
        THROW 53005, 'The Base Currency always has a rate of 1 - exchange rates are entered for the other currencies.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 53008, 'This currency is inactive. Activate it before adding exchange rates.', 1;

    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3)
        THROW 53000, 'Rate Type must be Official, Non-official or Market.', 1;

    IF @RateDate IS NULL
        THROW 53000, 'Rate Date is required.', 1;

    IF @RateDate > CAST(SYSUTCDATETIME() AS DATE)
        THROW 53000, 'Rate Date cannot be in the future.', 1;

    IF @Rate IS NULL OR @Rate <= 0
        THROW 53000, 'Rate must be greater than zero.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.ExchangeRates
               WHERE CurrencyId = @CurrencyId AND RateType = @RateType AND RateDate = @RateDate)
        THROW 53007, 'A rate for this currency, rate type and date already exists. Edit that rate instead.', 1;

    INSERT INTO masterdata.ExchangeRates (CurrencyId, RateType, RateDate, Rate, Notes, CreatedBy)
    VALUES (@CurrencyId, @RateType, @RateDate, @Rate, @Notes, @UserId);

    SET @NewId = SCOPE_IDENTITY();
END