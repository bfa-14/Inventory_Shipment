CREATE   PROCEDURE sales.usp_OutOfStockAudit_Search
    @Search       NVARCHAR(100) = NULL,
    @WarehouseId  INT           = NULL,
    @DateFrom     DATE          = NULL,
    @DateTo       DATE          = NULL,
    @PageNumber   INT           = 1,
    @PageSize     INT           = 50
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 50;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');

    SELECT a.Id, a.SalesDocumentId, a.DocumentNumber,
           a.ItemId, a.ItemCode, ItemName = i.ItemName,
           a.WarehouseId, WarehouseCode = w.WarehouseCode, WarehouseName = w.WarehouseName,
           a.QuantitySold, a.StockBefore, a.InventoryAfter,
           a.SoldAtUtc, a.UserId, UserName = u.FullName,
           a.SaleStatus, a.PolicySource,
           InvoiceStatus = CASE d.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Posted' WHEN 3 THEN N'Cancelled' ELSE N'Unknown' END,
           COUNT(*) OVER () AS TotalCount
    FROM sales.OutOfStockSaleAudit a
    INNER JOIN inventory.Items i ON i.Id = a.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = a.WarehouseId
    INNER JOIN sales.SalesDocuments d ON d.Id = a.SalesDocumentId
    LEFT  JOIN security.Users u ON u.Id = a.UserId
    WHERE (@WarehouseId IS NULL OR a.WarehouseId = @WarehouseId)
      AND (@DateFrom IS NULL OR a.SoldAtUtc >= CAST(@DateFrom AS DATETIME2(3)))
      AND (@DateTo   IS NULL OR a.SoldAtUtc <  DATEADD(DAY, 1, CAST(@DateTo AS DATETIME2(3))))
      AND (@Search IS NULL OR a.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%' OR a.DocumentNumber LIKE N'%' + @Search + N'%')
    ORDER BY a.SoldAtUtc DESC, a.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END

GO

