-- as of a date (default: today, UTC).
CREATE   PROCEDURE masterdata.usp_ExchangeRate_GetLatest
    @CurrencyId INT,
    @AsOfDate   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);

    SELECT x.Id, x.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol, c.DecimalPlaces,
           x.RateType, x.RateDate, x.Rate, x.Notes,
           x.CreatedAtUtc, x.CreatedBy, x.UpdatedAtUtc, x.UpdatedBy, x.RowVersion
    FROM
    (
        SELECT er.*, ROW_NUMBER() OVER (PARTITION BY er.RateType ORDER BY er.RateDate DESC) AS rn
        FROM masterdata.ExchangeRates er
        WHERE er.CurrencyId = @CurrencyId AND er.RateDate <= @AsOfDate
    ) x
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE x.rn = 1
    ORDER BY x.RateType;
END