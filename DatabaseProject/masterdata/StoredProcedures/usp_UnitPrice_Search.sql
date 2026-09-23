/* ================================================================== 4. Unit price procedures */

CREATE   PROCEDURE masterdata.usp_UnitPrice_Search
    @Search          NVARCHAR(200) = NULL,   -- Item Code or Item Name
    @BranchId        INT           = NULL,   -- a branch: its rows only; NULL: no branch filter
    @AllBranchesOnly BIT           = 0,      -- 1: only "All Branches" rows (BranchId IS NULL)
    @PriceListId     INT           = NULL,
    @ItemFamilyId    INT           = NULL,   -- family and its whole subtree
    @BaseUnitTypeId  INT           = NULL,   -- "Basic Unit" filter: the item's base unit type
    @UnitTypeId      INT           = NULL,   -- "Unit" filter: the priced unit's type
    @IsActive        BIT           = NULL,
    @SortColumn      NVARCHAR(30)  = N'ItemCode', -- ItemCode | ItemName | BranchName | UnitTypeName | PriceListName | Price | IsActive | UpdatedAtUtc
    @SortDirection   NVARCHAR(4)   = N'ASC',
    @PageNumber      INT           = 1,
    @PageSize        INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ItemCode', N'ItemName', N'BranchName', N'UnitTypeName', N'PriceListName', N'Price', N'IsActive', N'UpdatedAtUtc')
        SET @SortColumn = N'ItemCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT up.Id, up.BranchId, b.BranchCode, ISNULL(b.BranchName, N'All Branches') AS BranchName,
           up.ItemId, i.ItemCode, i.ItemName, but.UnitTypeName AS BaseUnitName,
           up.ItemUnitId, iu.UnitTypeId, ut.UnitTypeName, iu.PackingFormula, iu.SkuCode,
           up.PriceListId, pl.PriceListCode, pl.PriceListName,
           pl.CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces,
           up.Price, up.IsActive,
           up.CreatedAtUtc, up.CreatedBy, up.UpdatedAtUtc, up.UpdatedBy, up.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.UnitPrices up
    INNER JOIN inventory.Items i        ON i.Id   = up.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id  = up.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id  = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id  = up.PriceListId
    INNER JOIN masterdata.Currencies c  ON c.Id   = pl.CurrencyId
    LEFT  JOIN masterdata.Branches b    ON b.Id   = up.BranchId
    LEFT  JOIN inventory.ItemUnits bu   ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    LEFT  JOIN masterdata.UnitTypes but ON but.Id = bu.UnitTypeId
    WHERE (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%')
      AND (@BranchId IS NULL OR up.BranchId = @BranchId)
      AND (@AllBranchesOnly = 0 OR up.BranchId IS NULL)
      AND (@PriceListId IS NULL OR up.PriceListId = @PriceListId)
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BaseUnitTypeId IS NULL OR bu.UnitTypeId = @BaseUnitTypeId)
      AND (@UnitTypeId IS NULL OR iu.UnitTypeId = @UnitTypeId)
      AND (@IsActive IS NULL OR up.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName
                             WHEN N'BranchName' THEN ISNULL(b.BranchName, N'') WHEN N'UnitTypeName' THEN ut.UnitTypeName
                             WHEN N'PriceListName' THEN pl.PriceListName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName
                             WHEN N'BranchName' THEN ISNULL(b.BranchName, N'') WHEN N'UnitTypeName' THEN ut.UnitTypeName
                             WHEN N'PriceListName' THEN pl.PriceListName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Price' THEN up.Price END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Price' THEN up.Price END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(up.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(up.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'UpdatedAtUtc' THEN ISNULL(up.UpdatedAtUtc, up.CreatedAtUtc) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'UpdatedAtUtc' THEN ISNULL(up.UpdatedAtUtc, up.CreatedAtUtc) END DESC,
        i.ItemCode ASC, pl.PriceListName ASC, ut.UnitTypeName ASC, ISNULL(b.BranchName, N'') ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END

GO

