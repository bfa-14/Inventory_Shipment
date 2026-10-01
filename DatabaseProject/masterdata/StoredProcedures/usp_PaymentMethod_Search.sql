/* ================================================================== 5. Payment method procedures */

CREATE   PROCEDURE masterdata.usp_PaymentMethod_Search
    @Search        NVARCHAR(100) = NULL,
    @IsActive      BIT           = NULL,
    @SortColumn    NVARCHAR(30)  = N'MethodCode',   -- MethodCode | MethodName | IsActive
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
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'MethodCode', N'MethodName', N'IsActive') SET @SortColumn = N'MethodCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT m.Id, m.MethodCode, m.MethodName, m.Description, m.IsActive,
           UsedCount = (SELECT COUNT(*) FROM sales.ReceiptLines x WHERE x.PaymentMethodId = m.Id),
           m.CreatedAtUtc, m.CreatedBy, m.UpdatedAtUtc, m.UpdatedBy, m.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM masterdata.PaymentMethods m
    WHERE (@Search IS NULL OR m.MethodCode LIKE N'%' + @Search + N'%' OR m.MethodName LIKE N'%' + @Search + N'%')
      AND (@IsActive IS NULL OR m.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'MethodCode' THEN m.MethodCode WHEN N'MethodName' THEN m.MethodName END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'MethodCode' THEN m.MethodCode WHEN N'MethodName' THEN m.MethodName END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(m.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(m.IsActive AS INT) END DESC,
        m.MethodCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END

GO

