/* ================================================================== 3. Price list procedures */

CREATE   PROCEDURE masterdata.usp_PriceList_Search
    @Search        NVARCHAR(100) = NULL,          -- code or name
    @CurrencyId    INT           = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'PriceListCode', -- PriceListCode | PriceListName | CurrencyCode | IsActive | CreatedAtUtc
    @SortDirection NVARCHAR(4)   = N'ASC',
    @PageNumber    INT           = 1,
    @PageSize      INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'PriceListCode', N'PriceListName', N'CurrencyCode', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'PriceListCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT pl.Id, pl.PriceListCode, pl.PriceListName, pl.CurrencyId, c.CurrencyCode, c.CurrencyName, c.DecimalPlaces,
           pl.Description, pl.IsActive,
           PriceCount = (SELECT COUNT(*) FROM masterdata.UnitPrices up WHERE up.PriceListId = pl.Id),
           pl.CreatedAtUtc, pl.CreatedBy, pl.UpdatedAtUtc, pl.UpdatedBy, pl.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.PriceLists pl
    INNER JOIN masterdata.Currencies c ON c.Id = pl.CurrencyId
    WHERE (@Search IS NULL OR pl.PriceListCode LIKE N'%' + @Search + N'%' OR pl.PriceListName LIKE N'%' + @Search + N'%')
      AND (@CurrencyId IS NULL OR pl.CurrencyId = @CurrencyId)
      AND (@IsActive IS NULL OR pl.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'PriceListCode' THEN pl.PriceListCode WHEN N'PriceListName' THEN pl.PriceListName
                             WHEN N'CurrencyCode' THEN c.CurrencyCode END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'PriceListCode' THEN pl.PriceListCode WHEN N'PriceListName' THEN pl.PriceListName
                             WHEN N'CurrencyCode' THEN c.CurrencyCode END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(pl.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(pl.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN pl.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN pl.CreatedAtUtc END DESC,
        pl.PriceListCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END