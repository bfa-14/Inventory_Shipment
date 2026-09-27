/* ================================================================== 6. Master data: movement types */

CREATE   PROCEDURE masterdata.usp_MovementType_Search
    @Search        NVARCHAR(100) = NULL,
    @Stage         NVARCHAR(10)  = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'SortOrder',   -- SortOrder | TypeCode | TypeName | Stage | IsActive
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
    SET @Stage = NULLIF(LTRIM(RTRIM(@Stage)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'SortOrder', N'TypeCode', N'TypeName', N'Stage', N'IsActive') SET @SortColumn = N'SortOrder';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT t.Id, t.TypeCode, t.TypeName, t.Stage, t.SortOrder, t.IsActive,
           UsedCount = (SELECT COUNT(*) FROM logistics.Movements m WHERE m.MovementTypeId = t.Id),
           t.CreatedAtUtc, t.CreatedBy, t.UpdatedAtUtc, t.UpdatedBy, t.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.MovementTypes t
    WHERE (@Search IS NULL OR t.TypeCode LIKE N'%' + @Search + N'%' OR t.TypeName LIKE N'%' + @Search + N'%')
      AND (@Stage IS NULL OR t.Stage = @Stage)
      AND (@IsActive IS NULL OR t.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'TypeCode' THEN t.TypeCode WHEN N'TypeName' THEN t.TypeName WHEN N'Stage' THEN t.Stage END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'TypeCode' THEN t.TypeCode WHEN N'TypeName' THEN t.TypeName WHEN N'Stage' THEN t.Stage END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'SortOrder' THEN t.SortOrder END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'SortOrder' THEN t.SortOrder END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(t.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(t.IsActive AS INT) END DESC,
        t.SortOrder ASC, t.TypeCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END

GO

