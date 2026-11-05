/* ================================================================== 5. reporting.usp_ItemBalance_Rates */

-- The currency and the rates of its rate type up to Date To (1 base currency = Rate x the currency), oldest first.
CREATE   PROCEDURE reporting.usp_ItemBalance_Rates
    @CurrencyId INT,
    @RateType   TINYINT,
    @DateTo     DATE
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, CurrencyCode, CurrencyName, DecimalPlaces, IsBaseCurrency
    FROM masterdata.Currencies
    WHERE Id = @CurrencyId;

    SELECT RateDate, Rate
    FROM masterdata.ExchangeRates
    WHERE CurrencyId = @CurrencyId AND RateType = @RateType AND RateDate <= @DateTo
    ORDER BY RateDate;
END