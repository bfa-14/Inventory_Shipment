CREATE   PROCEDURE masterdata.usp_UnitType_Search
    @Search        NVARCHAR(50) = NULL,
    @IsActive      BIT          = NULL,
    @SortColumn    NVARCHAR(30) = N'UnitTypeName',  -- UnitTypeName | IsActive | CreatedAtUtc
    @SortDirection NVARCHAR(4)  = N'ASC',
    @PageNumber    INT          = 1,
    @PageSize      INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'UnitTypeName', N'IsActive', N'CreatedAtUtc') SET @SortColumn = N'UnitTypeName';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT u.Id, u.UnitTypeName, u.IsActive, u.IsContainer, u.CreatedAtUtc, u.CreatedBy, u.UpdatedAtUtc, u.UpdatedBy, u.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.UnitTypes u
    WHERE (@Search IS NULL OR u.UnitTypeName LIKE N'%' + @Search + N'%')
      AND (@IsActive IS NULL OR u.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'UnitTypeName' THEN u.UnitTypeName END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'UnitTypeName' THEN u.UnitTypeName END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(u.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(u.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN u.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN u.CreatedAtUtc END DESC,
        u.UnitTypeName ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END

GO

