CREATE   PROCEDURE masterdata.usp_Currency_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, CurrencyCode, CurrencyName, Symbol, DecimalPlaces, IsBaseCurrency, IsActive,
           CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.Currencies
    WHERE Id = @Id;
END

GO

