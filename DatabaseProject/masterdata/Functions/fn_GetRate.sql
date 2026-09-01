/* ------------------------------------------------------------------ 2. Function */

-- The rate in force for a currency/type on a date: the latest RateDate <= @AsOfDate.
-- Returns 1 for the base currency and NULL when no rate has been entered yet.
CREATE   FUNCTION masterdata.fn_GetRate
(
    @CurrencyId INT,
    @RateType   TINYINT,       -- 1 Official | 2 NonOfficial | 3 Market
    @AsOfDate   DATE
)
RETURNS DECIMAL(18,6)
AS
BEGIN
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1)
        RETURN 1;

    RETURN
    (
        SELECT TOP (1) Rate
        FROM masterdata.ExchangeRates
        WHERE CurrencyId = @CurrencyId AND RateType = @RateType AND RateDate <= @AsOfDate
        ORDER BY RateDate DESC
    );
END