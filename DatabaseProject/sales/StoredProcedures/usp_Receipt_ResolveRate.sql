/* The rate a receipt line pre-fills: the official rate on a date, 1 for the base currency, NULL when
   none is defined (a warning on the page, never an error here). */
CREATE   PROCEDURE sales.usp_Receipt_ResolveRate
    @CurrencyId INT,
    @AsOfDate   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);

    SELECT c.Id AS CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces, c.IsBaseCurrency,
           Rate     = masterdata.fn_GetRate(c.Id, 1, @AsOfDate),
           RateDate = CASE WHEN c.IsBaseCurrency = 1 THEN @AsOfDate
                           ELSE (SELECT TOP (1) RateDate FROM masterdata.ExchangeRates
                                 WHERE CurrencyId = c.Id AND RateType = 1 AND RateDate <= @AsOfDate ORDER BY RateDate DESC) END,
           BaseCurrencyCode = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1)
    FROM masterdata.Currencies c
    WHERE c.Id = @CurrencyId;
END

GO

