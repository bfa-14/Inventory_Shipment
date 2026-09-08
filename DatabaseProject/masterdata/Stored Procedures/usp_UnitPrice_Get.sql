CREATE   PROCEDURE masterdata.usp_UnitPrice_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT up.Id, up.BranchId, b.BranchCode, ISNULL(b.BranchName, N'All Branches') AS BranchName,
           up.ItemId, i.ItemCode, i.ItemName, but.UnitTypeName AS BaseUnitName,
           up.ItemUnitId, iu.UnitTypeId, ut.UnitTypeName, iu.PackingFormula, iu.SkuCode,
           up.PriceListId, pl.PriceListCode, pl.PriceListName,
           pl.CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces,
           up.Price, up.IsActive,
           up.CreatedAtUtc, up.CreatedBy, up.UpdatedAtUtc, up.UpdatedBy, up.RowVersion
    FROM masterdata.UnitPrices up
    INNER JOIN inventory.Items i        ON i.Id   = up.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id  = up.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id  = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id  = up.PriceListId
    INNER JOIN masterdata.Currencies c  ON c.Id   = pl.CurrencyId
    LEFT  JOIN masterdata.Branches b    ON b.Id   = up.BranchId
    LEFT  JOIN inventory.ItemUnits bu   ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    LEFT  JOIN masterdata.UnitTypes but ON but.Id = bu.UnitTypeId
    WHERE up.Id = @Id;
END