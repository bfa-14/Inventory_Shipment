/* ---------------------------------------------------------------- 3. Item lookup: sales units only */
CREATE   PROCEDURE inventory.usp_Item_Lookup
    @Search     NVARCHAR(200) = NULL,
    @ActiveOnly BIT           = 1,
    @IncludeId  INT           = NULL,
    @Top        INT           = 20,
    /* 1 = only items with a unit that may be sold. The sales invoice passes it; everything else
       leaves it 0 and sees every item, because an inventory count or a purchase is not a sale. */
    @SalesOnly  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @SalesOnly = ISNULL(@SalesOnly, 0);
    IF @Top IS NULL OR @Top < 1 SET @Top = 20;
    IF @Top > 200 SET @Top = 200;

    /* THE REPORTED UNIT FOLLOWS THE FILTER. With @SalesOnly the picker should land on a unit it is
       allowed to sell, so the sales unit is preferred over the base one; the base unit is still the
       fallback, and is what every other caller gets. */
    SELECT TOP (@Top) i.Id, i.ItemCode, i.ItemName, i.IsActive,
           ut.UnitTypeName AS BaseUnitName, bu.Id AS BaseUnitId
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
    ORDER BY CASE WHEN i.ItemCode LIKE @Search + N'%' THEN 0 ELSE 1 END, i.ItemCode;
END

GO

