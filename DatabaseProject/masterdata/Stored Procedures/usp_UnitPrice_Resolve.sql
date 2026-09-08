-- "No price is defined for the selected item, unit, price list, and branch." when empty.
CREATE   PROCEDURE masterdata.usp_UnitPrice_Resolve
    @ItemUnitId  INT,
    @PriceListId INT,
    @BranchId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (1) up.Id, up.BranchId, ISNULL(b.BranchName, N'All Branches') AS BranchName,
           up.ItemId, i.ItemCode, i.ItemName, up.ItemUnitId, ut.UnitTypeName, iu.PackingFormula,
           up.PriceListId, pl.PriceListName, pl.CurrencyId, c.CurrencyCode, c.DecimalPlaces, up.Price,
           CASE WHEN up.BranchId IS NULL THEN N'AllBranches' ELSE N'Branch' END AS PriceSource
    FROM masterdata.UnitPrices up
    INNER JOIN inventory.Items i        ON i.Id  = up.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id = up.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id = up.PriceListId
    INNER JOIN masterdata.Currencies c  ON c.Id  = pl.CurrencyId
    LEFT  JOIN masterdata.Branches b    ON b.Id  = up.BranchId
    WHERE up.ItemUnitId = @ItemUnitId AND up.PriceListId = @PriceListId AND up.IsActive = 1
      AND (up.BranchId = @BranchId OR up.BranchId IS NULL)
    ORDER BY CASE WHEN up.BranchId IS NULL THEN 1 ELSE 0 END;   -- branch-specific wins
END