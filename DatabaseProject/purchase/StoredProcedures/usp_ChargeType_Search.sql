CREATE   PROCEDURE purchase.usp_ChargeType_Search
    @Search              NVARCHAR(100) = NULL,   -- code or name (contains)
    @AllocationMethod    NVARCHAR(10)  = NULL,
    @IncludeInLandedCost BIT           = NULL,   -- "Cost impact" filter
    @IsActive            BIT           = NULL,
    @SortColumn          NVARCHAR(30)  = N'ChargeCode',
    @SortDirection       NVARCHAR(4)   = N'ASC',
    @PageNumber          INT           = 1,
    @PageSize            INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ChargeCode', N'ChargeName', N'AllocationMethod', N'IsActive', N'CreatedAtUtc') SET @SortColumn = N'ChargeCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT c.Id, c.ChargeCode, c.ChargeName, c.AllocationMethod, c.IncludeInLandedCost, c.IsRecoverableTax, c.Description, c.IsActive,
           UsageCount = (SELECT COUNT(*) FROM purchase.PurchaseCharges pc WHERE pc.ChargeTypeId = c.Id)
                      + (SELECT COUNT(*) FROM logistics.ContainerCharges cc WHERE cc.ChargeTypeId = c.Id),
           c.CreatedAtUtc, c.UpdatedAtUtc, c.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM purchase.ChargeTypes c
    WHERE (@Search IS NULL OR c.ChargeCode LIKE N'%' + @Search + N'%' OR c.ChargeName LIKE N'%' + @Search + N'%')
      AND (@AllocationMethod IS NULL OR c.AllocationMethod = @AllocationMethod)
      AND (@IncludeInLandedCost IS NULL OR c.IncludeInLandedCost = @IncludeInLandedCost)
      AND (@IsActive IS NULL OR c.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'ChargeCode' THEN c.ChargeCode WHEN N'ChargeName' THEN c.ChargeName WHEN N'AllocationMethod' THEN c.AllocationMethod END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'ChargeCode' THEN c.ChargeCode WHEN N'ChargeName' THEN c.ChargeName WHEN N'AllocationMethod' THEN c.AllocationMethod END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(c.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(c.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END DESC,
        c.ChargeCode
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END

GO

