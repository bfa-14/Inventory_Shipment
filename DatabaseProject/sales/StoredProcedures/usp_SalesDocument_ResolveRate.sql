CREATE   PROCEDURE sales.usp_SalesDocument_ResolveRate
    /* (56) Optional: the invoice currency is chosen first now, and its rate is known before any list. */
    @PriceListId INT     = NULL,
    @RateType    TINYINT = 1,
    @AsOfDate    DATE    = NULL,
    /* The currency the invoice is billed in. NULL answers for the price list's currency. */
    @CurrencyId  INT     = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);
    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) SET @RateType = 1;

    DECLARE @ListCurrencyId INT = (SELECT CurrencyId FROM masterdata.PriceLists WHERE Id = @PriceListId);
    -- a price list that does not exist answers nothing, as before
    IF @PriceListId IS NOT NULL AND @ListCurrencyId IS NULL RETURN;
    DECLARE @Answer INT = COALESCE(@CurrencyId, @ListCurrencyId);

    /* BOTH CURRENCIES. The invoice's rate values the invoice in the base currency; the price list's
       converts its prices into the invoice currency (list price x invoice rate / list rate). */
    SELECT PriceListId = @PriceListId, c.Id AS CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces, c.IsBaseCurrency,
           RateType = @RateType,
           Rate     = masterdata.fn_GetRate(c.Id, @RateType, @AsOfDate),
           RateDate = CASE WHEN c.IsBaseCurrency = 1 THEN @AsOfDate
                           ELSE (SELECT TOP (1) RateDate FROM masterdata.ExchangeRates
                                 WHERE CurrencyId = c.Id AND RateType = @RateType AND RateDate <= @AsOfDate ORDER BY RateDate DESC) END,
           BaseCurrencyCode = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1),
           PriceListCurrencyId     = pc.Id,
           PriceListCurrencyCode   = pc.CurrencyCode,
           PriceListIsBaseCurrency = pc.IsBaseCurrency,
           PriceListRate           = CASE WHEN pc.IsBaseCurrency = 1 THEN 1 ELSE masterdata.fn_GetRate(pc.Id, @RateType, @AsOfDate) END,
           PriceListRateDate       = CASE WHEN pc.IsBaseCurrency = 1 THEN @AsOfDate
                                          ELSE (SELECT TOP (1) RateDate FROM masterdata.ExchangeRates
                                                WHERE CurrencyId = pc.Id AND RateType = @RateType AND RateDate <= @AsOfDate ORDER BY RateDate DESC) END
    FROM masterdata.Currencies c
    LEFT JOIN masterdata.Currencies pc ON pc.Id = @ListCurrencyId
    WHERE c.Id = @Answer;
END

GO

