CREATE   PROCEDURE masterdata.usp_Port_Search
    @Search        NVARCHAR(100) = NULL,
    @Kind          NVARCHAR(10)  = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'PortCode',   -- PortCode | PortName | CountryCode | Kind | IsActive
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
    SET @Kind = NULLIF(LTRIM(RTRIM(@Kind)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'PortCode', N'PortName', N'CountryCode', N'Kind', N'IsActive') SET @SortColumn = N'PortCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT p.Id, p.PortCode, p.PortName, p.CountryCode, p.Kind, p.IsActive,
           p.CreatedAtUtc, p.CreatedBy, p.UpdatedAtUtc, p.UpdatedBy, p.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.Ports p
    WHERE (@Search IS NULL OR p.PortCode LIKE N'%' + @Search + N'%' OR p.PortName LIKE N'%' + @Search + N'%')
      AND (@Kind IS NULL OR p.Kind = @Kind)
      AND (@IsActive IS NULL OR p.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'PortCode' THEN p.PortCode WHEN N'PortName' THEN p.PortName
                                                                 WHEN N'CountryCode' THEN p.CountryCode WHEN N'Kind' THEN p.Kind END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'PortCode' THEN p.PortCode WHEN N'PortName' THEN p.PortName
                                                                 WHEN N'CountryCode' THEN p.CountryCode WHEN N'Kind' THEN p.Kind END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(p.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(p.IsActive AS INT) END DESC,
        p.PortCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

