/* ================================================================== 2. Rates and documents, defined once */

/* The multiplier from one currency to the payment currency: 1 when they are the same; otherwise the
   payment's rate over the other currency's official rate on the date (both per 1 base). NULL when the
   other currency has no rate - the caller turns that into a message. */
CREATE   FUNCTION purchase.fn_RateToPayment (@FromCurrencyId INT, @PaymentCurrencyId INT, @PaymentRate DECIMAL(18,6), @AsOfDate DATE)
RETURNS DECIMAL(24,12)
AS
BEGIN
    IF @FromCurrencyId = @PaymentCurrencyId RETURN 1;
    DECLARE @FromRate DECIMAL(18,6) = masterdata.fn_GetRate(@FromCurrencyId, 1, @AsOfDate);
    IF @FromRate IS NULL OR @FromRate <= 0 OR @PaymentRate IS NULL OR @PaymentRate <= 0 RETURN NULL;
    RETURN CONVERT(DECIMAL(24,12), CONVERT(DECIMAL(38,18), @PaymentRate) / @FromRate);
END

GO

