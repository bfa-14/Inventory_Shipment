CREATE   PROCEDURE masterdata.usp_ContainerType_Search
    @Search        NVARCHAR(100) = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'TypeCode',   -- TypeCode | TypeName | MaxUnits | IsActive
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
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'TypeCode', N'TypeName', N'MaxUnits', N'IsActive') SET @SortColumn = N'TypeCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT c.Id, c.TypeCode, c.TypeName, c.MaxUnits, c.MaxWeightKg, c.MaxVolumeCbm, c.Description, c.IsActive,
           UsedCount = (SELECT COUNT(*) FROM logistics.Containers x WHERE x.ContainerTypeId = c.Id),
           c.CreatedAtUtc, c.CreatedBy, c.UpdatedAtUtc, c.UpdatedBy, c.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.ContainerTypes c
    WHERE (@Search IS NULL OR c.TypeCode LIKE N'%' + @Search + N'%' OR c.TypeName LIKE N'%' + @Search + N'%')
      AND (@IsActive IS NULL OR c.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'TypeCode' THEN c.TypeCode WHEN N'TypeName' THEN c.TypeName END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'TypeCode' THEN c.TypeCode WHEN N'TypeName' THEN c.TypeName END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'MaxUnits' THEN c.MaxUnits END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'MaxUnits' THEN c.MaxUnits END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(c.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(c.IsActive AS INT) END DESC,
        c.TypeCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

