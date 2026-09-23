CREATE   PROCEDURE masterdata.usp_PriceList_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT pl.Id, pl.PriceListCode, pl.PriceListName, pl.CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces, pl.IsActive
    FROM masterdata.PriceLists pl
    INNER JOIN masterdata.Currencies c ON c.Id = pl.CurrencyId
    WHERE (@ActiveOnly = 0 OR pl.IsActive = 1 OR pl.Id = @IncludeId)
    ORDER BY pl.PriceListName;
END

GO

