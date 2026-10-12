/* The multiplier a line or an allocation pre-fills: from a currency to the payment currency, on a date.
   NULL when either has no official rate (a warning on the page, never an error here). */
CREATE   PROCEDURE purchase.usp_Payment_RateToPayment
    @FromCurrencyId    INT,
    @PaymentCurrencyId INT,
    @PaymentRate       DECIMAL(18,6) = NULL,  -- NULL = the payment currency's official rate on the date
    @AsOfDate          DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @PayRate DECIMAL(18,6) = COALESCE(@PaymentRate, masterdata.fn_GetRate(@PaymentCurrencyId, 1, @AsOfDate));
    SELECT FromCurrencyId = @FromCurrencyId, PaymentCurrencyId = @PaymentCurrencyId, PaymentRate = @PayRate,
           FromRate = masterdata.fn_GetRate(@FromCurrencyId, 1, @AsOfDate),
           RateToPayment = purchase.fn_RateToPayment(@FromCurrencyId, @PaymentCurrencyId, @PayRate, @AsOfDate);
END

GO

