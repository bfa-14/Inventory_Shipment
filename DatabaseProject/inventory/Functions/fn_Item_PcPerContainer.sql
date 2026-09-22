CREATE   FUNCTION inventory.fn_Item_PcPerContainer (@ItemId INT)
RETURNS INT
AS
BEGIN
    RETURN (SELECT u.PackingFormula
            FROM inventory.ItemUnits u
            INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
            WHERE u.ItemId = @ItemId AND t.UnitTypeName = N'Container');
END