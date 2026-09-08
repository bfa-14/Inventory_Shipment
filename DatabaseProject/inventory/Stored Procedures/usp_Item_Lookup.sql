CREATE   PROCEDURE inventory.usp_Item_Lookup
    @Search     NVARCHAR(200) = NULL,
    @ActiveOnly BIT           = 1,
    @IncludeId  INT           = NULL,
    @Top        INT           = 20
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @Top IS NULL OR @Top < 1 SET @Top = 20;
    IF @Top > 200 SET @Top = 200;

    SELECT TOP (@Top) i.Id, i.ItemCode, i.ItemName, i.IsActive,
           ut.UnitTypeName AS BaseUnitName, bu.Id AS BaseUnitId
    FROM inventory.Items i
    LEFT JOIN inventory.ItemUnits bu    ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    LEFT JOIN masterdata.UnitTypes ut   ON ut.Id = bu.UnitTypeId
    WHERE (@ActiveOnly = 0 OR i.IsActive = 1 OR i.Id = @IncludeId)
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%')
    ORDER BY CASE WHEN i.ItemCode LIKE @Search + N'%' THEN 0 ELSE 1 END, i.ItemCode;
END