CREATE   PROCEDURE masterdata.usp_ExchangeRate_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT er.Id, er.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol, c.DecimalPlaces,
           er.RateType, er.RateDate, er.Rate, er.Notes,
           er.CreatedAtUtc, er.CreatedBy, er.UpdatedAtUtc, er.UpdatedBy, er.RowVersion
    FROM masterdata.ExchangeRates er
    INNER JOIN masterdata.Currencies c ON c.Id = er.CurrencyId
    WHERE er.Id = @Id;
END