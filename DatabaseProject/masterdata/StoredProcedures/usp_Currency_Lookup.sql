-- visible (the value already saved on the record being edited).
CREATE   PROCEDURE masterdata.usp_Currency_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, CurrencyCode, CurrencyName, Symbol, DecimalPlaces, IsBaseCurrency, IsActive
    FROM masterdata.Currencies
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY IsBaseCurrency DESC, CurrencyCode;
END

GO

