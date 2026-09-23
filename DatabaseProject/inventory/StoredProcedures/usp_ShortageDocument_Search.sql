/* ------------------------------------------------------------------ 4b. Search / Get */

CREATE   PROCEDURE inventory.usp_ShortageDocument_Search
    @Search        NVARCHAR(100) = NULL,    -- number or description
    @WarehouseId   INT          = NULL,
    @BranchId      INT          = NULL,
    @SupplierId    INT          = NULL,
    @Status        TINYINT      = NULL,     -- 1 Draft | 2 Posted
    @CreatedBy     INT          = NULL,
    @DateFrom      DATE         = NULL,
    @DateTo        DATE         = NULL,
    @SortColumn    NVARCHAR(30) = N'DocumentDate',  -- DocumentNumber | DocumentDate | Description | WarehouseName | SupplierName | Status | CreatedAtUtc
    @SortDirection NVARCHAR(4)  = N'DESC',
    @PageNumber    INT          = 1,
    @PageSize      INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'Description', N'WarehouseName', N'SupplierName', N'Status', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT d.Id, d.DocumentNumber, d.Description, d.DocumentDate, d.BranchId, b.BranchName, d.WarehouseId, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, d.LeadTimeMonths, d.MonthsOfHistory, d.Status,
           d.TotalLines, d.TotalShortageBase, d.TotalRequiredBase, d.TotalContainers, d.ContainersRounded,
           PurchaseOrders = (SELECT COUNT(*) FROM purchase.PurchaseDocuments p WHERE p.SourceShortageId = d.Id AND p.Status <> 3),
           d.PostedAtUtc, pu.FullName AS PostedByName, d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM inventory.ShortageDocuments d
    INNER JOIN masterdata.Branches b ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    WHERE (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.Description LIKE N'%' + @Search + N'%')
      AND (@WarehouseId IS NULL OR d.WarehouseId = @WarehouseId)
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Status IS NULL OR d.Status = @Status)
      AND (@CreatedBy IS NULL OR d.CreatedBy = @CreatedBy)
      AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'Description' THEN d.Description
                             WHEN N'WarehouseName' THEN w.WarehouseName WHEN N'SupplierName' THEN sp.PartyName END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'Description' THEN d.Description
                             WHEN N'WarehouseName' THEN w.WarehouseName WHEN N'SupplierName' THEN sp.PartyName END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END DESC,
        d.DocumentDate DESC, d.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END

GO

