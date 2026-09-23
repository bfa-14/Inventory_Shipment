CREATE   PROCEDURE masterdata.usp_ExchangeRate_Update
    @Id         INT,
    @CurrencyId INT,
    @RateType   TINYINT,
    @RateDate   DATE,
    @Rate       DECIMAL(18,6),
    @Notes      NVARCHAR(300) = NULL,
    @RowVersion BINARY(8)     = NULL,   -- NULL skips the concurrency check
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    IF NOT EXISTS (SELECT 1 FROM masterdata.ExchangeRates WHERE Id = @Id)
        THROW 53006, 'Exchange rate not found.', 1;

    IF @CurrencyId IS NULL
        THROW 53000, 'Currency is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId)
        THROW 53006, 'Currency not found.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1)
        THROW 53005, 'The Base Currency always has a rate of 1 - exchange rates are entered for the other currencies.', 1;

    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3)
        THROW 53000, 'Rate Type must be Official, Non-official or Market.', 1;

    IF @RateDate IS NULL
        THROW 53000, 'Rate Date is required.', 1;

    IF @RateDate > CAST(SYSUTCDATETIME() AS DATE)
        THROW 53000, 'Rate Date cannot be in the future.', 1;

    IF @Rate IS NULL OR @Rate <= 0
        THROW 53000, 'Rate must be greater than zero.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.ExchangeRates
               WHERE CurrencyId = @CurrencyId AND RateType = @RateType AND RateDate = @RateDate AND Id <> @Id)
        THROW 53007, 'A rate for this currency, rate type and date already exists. Edit that rate instead.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.ExchangeRates WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 53004, 'This exchange rate was modified by another user. Reload the page and try again.', 1;

    UPDATE masterdata.ExchangeRates
    SET CurrencyId   = @CurrencyId,
        RateType     = @RateType,
        RateDate     = @RateDate,
        Rate         = @Rate,
        Notes        = @Notes,
        UpdatedAtUtc = SYSUTCDATETIME(),
        UpdatedBy    = @UserId
    WHERE Id = @Id;
END

GO

