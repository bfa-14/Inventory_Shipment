/* ------------------------------------------------------------------ 2. Procedures */

-- Paged, filtered, sorted list. Returns the page rows plus TotalCount (same value on every row).
CREATE   PROCEDURE masterdata.usp_Branch_Search
    @Search        NVARCHAR(150) = NULL,        -- matches Branch Code or Branch Name (contains)
    @IsActive      BIT           = NULL,        -- NULL = all
    @IsMainBranch  BIT           = NULL,        -- NULL = all
    @SortColumn    NVARCHAR(30)  = N'BranchCode', -- BranchCode | BranchName | Address | IsMainBranch | IsActive | CreatedAtUtc
    @SortDirection NVARCHAR(4)   = N'ASC',      -- ASC | DESC
    @PageNumber    INT           = 1,
    @PageSize      INT           = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'BranchCode', N'BranchName', N'Address', N'IsMainBranch', N'IsActive', N'CreatedAtUtc')
        SET @SortColumn = N'BranchCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC')
        SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT b.Id, b.BranchCode, b.BranchName, b.Address, b.IsMainBranch, b.IsActive,
           b.CreatedAtUtc, b.CreatedBy, b.UpdatedAtUtc, b.UpdatedBy, b.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.Branches b
    WHERE (@Search IS NULL OR b.BranchCode LIKE N'%' + @Search + N'%' OR b.BranchName LIKE N'%' + @Search + N'%')
      AND (@IsActive IS NULL OR b.IsActive = @IsActive)
      AND (@IsMainBranch IS NULL OR b.IsMainBranch = @IsMainBranch)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'BranchCode' THEN b.BranchCode WHEN N'BranchName' THEN b.BranchName WHEN N'Address' THEN b.Address END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'BranchCode' THEN b.BranchCode WHEN N'BranchName' THEN b.BranchName WHEN N'Address' THEN b.Address END
        END DESC,
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'IsMainBranch' THEN CAST(b.IsMainBranch AS INT) WHEN N'IsActive' THEN CAST(b.IsActive AS INT) END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'IsMainBranch' THEN CAST(b.IsMainBranch AS INT) WHEN N'IsActive' THEN CAST(b.IsActive AS INT) END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN b.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN b.CreatedAtUtc END DESC,
        b.BranchCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END

GO

