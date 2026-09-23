CREATE   PROCEDURE masterdata.usp_Currency_GetBase
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (1) Id, CurrencyCode, CurrencyName, Symbol, DecimalPlaces, IsBaseCurrency, IsActive,
           CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.Currencies
    WHERE IsBaseCurrency = 1 AND IsActive = 1;
END

GO

