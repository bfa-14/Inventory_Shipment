/* ================================================================== 2. Pieces per container: 1 is "not specified" */

-- Re-created (100) from the body of script 54: + A PACKING FORMULA OF 1 MEANS "NOT SPECIFIED" (the owner: a container unit of
-- 1 piece is the value nobody typed). NULL then, as for an item without a Container unit, so the fill is unknown, no
-- over-capacity warning is raised and Auto-plan asks for the Container unit. The PackingFormula of the item's Container unit
-- (the first by Id), NULL when it has none or a value <= 1. Always one row, so a CROSS APPLY keeps the item.
CREATE   FUNCTION logistics.fn_ItemPcsPerContainer (@ItemId INT)
RETURNS TABLE
AS
RETURN
SELECT PcsPerContainer = (SELECT TOP (1) CASE WHEN u.PackingFormula > 1 THEN u.PackingFormula END
                          FROM inventory.ItemUnits u
                          INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
                          WHERE u.ItemId = @ItemId AND t.IsContainer = 1
                          ORDER BY u.Id);

GO

