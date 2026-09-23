/* ------------------------------------------------------------------ 2. Procedures */

CREATE   PROCEDURE masterdata.usp_Brand_Search
    @Search        NVARCHAR(150) = NULL,        -- matches Brand Code or Brand Name (contains)
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'BrandCode', -- BrandCode | BrandName | IsActive | CreatedAtUtc
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
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'BrandCode', N'BrandName', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'BrandCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC')
        SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT b.Id, b.BrandCode, b.BrandName, b.Description, b.IsActive,
           b.CreatedAtUtc, b.CreatedBy, b.UpdatedAtUtc, b.UpdatedBy, b.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.Brands b
    WHERE (@Search IS NULL OR b.BrandCode LIKE N'%' + @Search + N'%' OR b.BrandName LIKE N'%' + @Search + N'%')
      AND (@IsActive IS NULL OR b.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'BrandCode' THEN b.BrandCode WHEN N'BrandName' THEN b.BrandName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'BrandCode' THEN b.BrandCode WHEN N'BrandName' THEN b.BrandName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(b.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(b.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN b.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN b.CreatedAtUtc END DESC,
        b.BrandCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END

GO

