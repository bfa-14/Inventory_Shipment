CREATE   PROCEDURE masterdata.usp_PriceList_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT pl.Id, pl.PriceListCode, pl.PriceListName, pl.CurrencyId, c.CurrencyCode, c.CurrencyName, c.DecimalPlaces,
           pl.Description, pl.IsActive,
           PriceCount = (SELECT COUNT(*) FROM masterdata.UnitPrices up WHERE up.PriceListId = pl.Id),
           pl.CreatedAtUtc, pl.CreatedBy, pl.UpdatedAtUtc, pl.UpdatedBy, pl.RowVersion
    FROM masterdata.PriceLists pl
    INNER JOIN masterdata.Currencies c ON c.Id = pl.CurrencyId
    WHERE pl.Id = @Id;
END