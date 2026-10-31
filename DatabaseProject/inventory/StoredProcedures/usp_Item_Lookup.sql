/* ================================================================== 6. The item picker: BIVAC items only, and no 20-row cut */

-- Re-created (66) from the body of script 30: + @BivacOnly, + IsBivac in the rows, @Top NULL = every item.
CREATE   PROCEDURE inventory.usp_Item_Lookup
    @Search     NVARCHAR(200) = NULL,
    @ActiveOnly BIT           = 1,
    @IncludeId  INT           = NULL,
    @Top        INT           = NULL,   -- (66) NULL = every matching item (it was 20: see below)
    /* 1 = only items with a unit that may be sold. The sales invoice passes it; everything else
       leaves it 0 and sees every item, because an inventory count or a purchase is not a sale. */
    @SalesOnly  BIT           = 0,
    /* (66) 1 = only items flagged "BIVAC Item" (inventory.Items.IsBivac): the lines of a document type whose
       BivacItemsOnly is 1 (BIVAC Out). 0 = every item, as before. */
    @BivacOnly  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @SalesOnly = ISNULL(@SalesOnly, 0);
    SET @BivacOnly = ISNULL(@BivacOnly, 0);
    /* (66) NO CUT BY DEFAULT. The pages load this list ONCE, without a search, and filter it in the browser; the
       API never sends @Top. The old default of 20 (at most 200) therefore hid every item after the 20th from
       every line dropdown. NULL now means every matching item; a caller that sends @Top gets at most that. */
    IF @Top IS NULL OR @Top < 1 SET @Top = 2147483647;

    /* THE REPORTED UNIT FOLLOWS THE FILTER. With @SalesOnly the picker should land on a unit it is
       allowed to sell, so the sales unit is preferred over the base one; the base unit is still the
       fallback, and is what every other caller gets. */
    SELECT TOP (@Top) i.Id, i.ItemCode, i.ItemName, i.IsActive,
           ut.UnitTypeName AS BaseUnitName, bu.Id AS BaseUnitId,
           i.IsBivac   -- (66)
    FROM inventory.Items i
    OUTER APPLY (
        SELECT TOP (1) u.Id, u.UnitTypeId
        FROM inventory.ItemUnits u
        WHERE u.ItemId = i.Id
          AND (@SalesOnly = 0 OR u.IsSalesUnit = 1)
        ORDER BY CASE WHEN @SalesOnly = 1 AND u.IsSalesUnit = 1 THEN 0
                      WHEN u.IsBaseUnit = 1 THEN 1
                      ELSE 2 END, u.Id
    ) bu
    LEFT JOIN masterdata.UnitTypes ut ON ut.Id = bu.UnitTypeId
    WHERE (@ActiveOnly = 0 OR i.IsActive = 1 OR i.Id = @IncludeId)
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%')
      /* AN ITEM WITH NO SELLABLE UNIT IS NOT OFFERED - except the one the caller names with
         @IncludeId, so a saved line whose item was since taken off sale still resolves. */
      AND (@SalesOnly = 0 OR i.Id = @IncludeId
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits su WHERE su.ItemId = i.Id AND su.IsSalesUnit = 1))
      /* (66) BIVAC ITEMS ONLY when asked - again except the one named by @IncludeId, so a saved line whose item
         was since un-flagged still resolves (Save and Post refuse it with 62000). */
      AND (@BivacOnly = 0 OR i.IsBivac = 1 OR i.Id = @IncludeId)
    ORDER BY CASE WHEN i.ItemCode LIKE @Search + N'%' THEN 0 ELSE 1 END, i.ItemCode;
END

GO

