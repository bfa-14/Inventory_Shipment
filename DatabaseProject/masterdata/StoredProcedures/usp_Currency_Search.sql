/* ------------------------------------------------------------------ 3. Currency procedures */

CREATE   PROCEDURE masterdata.usp_Currency_Search
    @Search         NVARCHAR(100) = NULL,          -- matches Currency Code or Currency Name (contains)
    @IsActive       BIT           = NULL,          -- NULL = all
    @IsBaseCurrency BIT           = NULL,          -- NULL = all
    @SortColumn     NVARCHAR(30)  = N'CurrencyCode', -- CurrencyCode | CurrencyName | DecimalPlaces | IsBaseCurrency | IsActive | CreatedAtUtc
    @SortDirection  NVARCHAR(4)   = N'ASC',
    @PageNumber     INT           = 1,
    @PageSize       INT           = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'CurrencyCode', N'CurrencyName', N'DecimalPlaces', N'IsBaseCurrency', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'CurrencyCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC')
        SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT c.Id, c.CurrencyCode, c.CurrencyName, c.Symbol, c.DecimalPlaces, c.IsBaseCurrency, c.IsActive,
           c.CreatedAtUtc, c.CreatedBy, c.UpdatedAtUtc, c.UpdatedBy, c.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.Currencies c
    WHERE (@Search IS NULL OR c.CurrencyCode LIKE N'%' + @Search + N'%' OR c.CurrencyName LIKE N'%' + @Search + N'%')
      AND (@IsActive IS NULL OR c.IsActive = @IsActive)
      AND (@IsBaseCurrency IS NULL OR c.IsBaseCurrency = @IsBaseCurrency)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'CurrencyCode' THEN c.CurrencyCode WHEN N'CurrencyName' THEN c.CurrencyName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'CurrencyCode' THEN c.CurrencyCode WHEN N'CurrencyName' THEN c.CurrencyName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DecimalPlaces' THEN CAST(c.DecimalPlaces AS INT)
                             WHEN N'IsBaseCurrency' THEN CAST(c.IsBaseCurrency AS INT)
                             WHEN N'IsActive' THEN CAST(c.IsActive AS INT) END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DecimalPlaces' THEN CAST(c.DecimalPlaces AS INT)
                             WHEN N'IsBaseCurrency' THEN CAST(c.IsBaseCurrency AS INT)
                             WHEN N'IsActive' THEN CAST(c.IsActive AS INT) END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END DESC,
        c.CurrencyCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END

GO

