/* ==================================================================================================
   33: The sales invoice is billed in a currency of its own
   --------------------------------------------------------------------------------------------------
   The invoice currency was always the price list's, snapshotted on the header. It is now a choice:
   the header may bill in another currency, and the lines are converted into it.

   TWO RATES, NOT ONE. masterdata.fn_GetUnitPrice answers in the PRICE LIST's currency. Dividing by
   that currency's rate gives the base currency, and multiplying by the INVOICE currency's rate gives
   what the customer is billed. Both are 1 when a base-currency list prices a base-currency invoice,
   so the ordinary case is unchanged.

   @ExchangeRate stays the rate of the INVOICE currency - it is what TotalAmountBase divides by, and
   a typed override still overrides only that. The price list's rate is always the published one; a
   typed rate must not be used to undo the list currency, or the lines would be priced twice.

   Nothing is stored that was not stored before: SalesDocuments already had CurrencyId, RateType,
   ExchangeRate, TotalAmount (invoice currency) and TotalAmountBase (base currency).
   ================================================================================================== */

CREATE   PROCEDURE sales.usp_SalesDocument_ResolveRate
    @PriceListId INT,
    @RateType    TINYINT = 1,
    @AsOfDate    DATE    = NULL,
    /* The currency the invoice is billed in, when the header chose one that is not the price
       list's. NULL answers for the price list's currency, as it always did. */
    @CurrencyId  INT     = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);
    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) SET @RateType = 1;

    DECLARE @Answer INT = COALESCE(@CurrencyId, (SELECT CurrencyId FROM masterdata.PriceLists WHERE Id = @PriceListId));

    SELECT pl.Id AS PriceListId, c.Id AS CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces, c.IsBaseCurrency,
           RateType = @RateType,
           Rate     = masterdata.fn_GetRate(c.Id, @RateType, @AsOfDate),
           RateDate = CASE WHEN c.IsBaseCurrency = 1 THEN @AsOfDate
                           ELSE (SELECT TOP (1) RateDate FROM masterdata.ExchangeRates
                                 WHERE CurrencyId = c.Id AND RateType = @RateType AND RateDate <= @AsOfDate ORDER BY RateDate DESC) END,
           BaseCurrencyCode = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1)
    FROM masterdata.PriceLists pl
    INNER JOIN masterdata.Currencies c ON c.Id = @Answer
    WHERE pl.Id = @PriceListId;
END

GO

