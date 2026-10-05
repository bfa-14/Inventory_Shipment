CREATE   PROCEDURE masterdata.usp_AttachmentType_Search
    @Search        NVARCHAR(100) = NULL,
    @Category      NVARCHAR(30)  = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'SortOrder',   -- SortOrder | Category | SubType | IsActive
    @SortDirection NVARCHAR(4)   = N'ASC',
    @PageNumber    INT           = 1,
    @PageSize      INT           = 10,
    @DocumentKind  NVARCHAR(20)  = NULL            -- (48) the types used for this kind
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @Category = NULLIF(LTRIM(RTRIM(@Category)), N'');
    SET @DocumentKind = NULLIF(LTRIM(RTRIM(@DocumentKind)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'SortOrder', N'Category', N'SubType', N'IsActive') SET @SortColumn = N'SortOrder';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT a.Id, a.Category, a.SubType, a.AppliesTo, a.SortOrder, a.IsActive,
           UsedFor = (SELECT STRING_AGG(k.Code, N',') WITHIN GROUP (ORDER BY k.SortOrder)
                      FROM masterdata.AttachmentTypeUsages u
                      INNER JOIN masterdata.fn_AttachmentDocumentKinds() k ON k.Code = u.DocumentKind
                      WHERE u.AttachmentTypeId = a.Id),
           a.CreatedAtUtc, a.CreatedBy, a.UpdatedAtUtc, a.UpdatedBy, a.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.AttachmentTypes a
    WHERE (@Search IS NULL OR a.Category LIKE N'%' + @Search + N'%' OR a.SubType LIKE N'%' + @Search + N'%')
      AND (@Category IS NULL OR a.Category = @Category)
      AND (@IsActive IS NULL OR a.IsActive = @IsActive)
      AND (@DocumentKind IS NULL OR EXISTS (SELECT 1 FROM masterdata.AttachmentTypeUsages u WHERE u.AttachmentTypeId = a.Id AND u.DocumentKind = @DocumentKind))
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'Category' THEN a.Category WHEN N'SubType' THEN a.SubType END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'Category' THEN a.Category WHEN N'SubType' THEN a.SubType END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'SortOrder' THEN a.SortOrder END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'SortOrder' THEN a.SortOrder END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(a.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(a.IsActive AS INT) END DESC,
        a.SortOrder, a.Category, a.SubType
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END

GO

