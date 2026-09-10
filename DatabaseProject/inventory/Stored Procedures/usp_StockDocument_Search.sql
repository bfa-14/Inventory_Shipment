/* ------------------------------------------------------------------ 4a. Search / Get */

CREATE   PROCEDURE inventory.usp_StockDocument_Search
    @DocumentTypeCode NVARCHAR(20) = NULL,   -- INV_IN | INV_OUT | NULL = both
    @Search           NVARCHAR(100) = NULL,  -- number, reference or notes
    @BranchId         INT          = NULL,
    @WarehouseId      INT          = NULL,
    @Status           TINYINT      = NULL,   -- 1 Draft | 2 Posted | 3 Cancelled
    @DateFrom         DATE         = NULL,
    @DateTo           DATE         = NULL,
    @SortColumn       NVARCHAR(30) = N'DocumentDate',  -- DocumentNumber | DocumentDate | BranchName | WarehouseName | Status | TotalCost | CreatedAtUtc
    @SortDirection    NVARCHAR(4)  = N'DESC',
    @PageNumber       INT          = 1,
    @PageSize         INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'BranchName', N'WarehouseName', N'Status', N'TotalCost', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT d.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection,
           d.DocumentNumber, d.DocumentDate, d.BranchId, b.BranchName, d.WarehouseId, w.WarehouseName,
           d.ReasonId, r.ReasonName, d.ReferenceNo, c.CurrencyCode, d.Status,
           d.TotalItems, d.TotalQuantity, d.TotalCost,
           d.PostedAtUtc, pu.FullName AS PostedByName, d.CancelledAtUtc,
           d.CreatedAtUtc, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM inventory.StockDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN inventory.StockReasons r   ON r.Id = d.ReasonId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    WHERE dt.Family = N'Inventory'
      AND (@DocumentTypeCode IS NULL OR dt.Code = @DocumentTypeCode)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.ReferenceNo LIKE N'%' + @Search + N'%' OR d.Notes LIKE N'%' + @Search + N'%')
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR d.WarehouseId = @WarehouseId)
      AND (@Status IS NULL OR d.Status = @Status)
      AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'BranchName' THEN b.BranchName WHEN N'WarehouseName' THEN w.WarehouseName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'BranchName' THEN b.BranchName WHEN N'WarehouseName' THEN w.WarehouseName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'TotalCost' THEN d.TotalCost END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'TotalCost' THEN d.TotalCost END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END DESC,
        d.DocumentDate DESC, d.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END