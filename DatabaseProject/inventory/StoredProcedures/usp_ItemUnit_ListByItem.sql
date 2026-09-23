CREATE   PROCEDURE inventory.usp_ItemUnit_ListByItem
    @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit
    FROM inventory.ItemUnits u
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
    WHERE u.ItemId = @ItemId
    ORDER BY u.IsBaseUnit DESC, u.PackingFormula, ut.UnitTypeName;
END

GO

