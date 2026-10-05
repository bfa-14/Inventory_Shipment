/* ================================================================== 1. Pieces per container of an item */

-- The PackingFormula of the item's Container unit (the first by Id), NULL when it has none or a value <= 0. Always one
-- row, so a CROSS APPLY keeps the item.
CREATE   FUNCTION logistics.fn_ItemPcsPerContainer (@ItemId INT)
RETURNS TABLE
AS
RETURN
SELECT PcsPerContainer = (SELECT TOP (1) CASE WHEN u.PackingFormula > 0 THEN u.PackingFormula END
                          FROM inventory.ItemUnits u
                          INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
                          WHERE u.ItemId = @ItemId AND t.IsContainer = 1
                          ORDER BY u.Id);

GO

