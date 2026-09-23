
CREATE   PROCEDURE logistics.usp_Container_Search
    @Search              NVARCHAR(100) = NULL,   -- ref, container no., B/L, PI no., commercial invoice no.
    @ContainerRef        NVARCHAR(30)  = NULL,
    @ContainerNo         NVARCHAR(20)  = NULL,
    @SupplierId          INT           = NULL,
    @PurchaseDocumentId  INT           = NULL,
    @CommercialInvoiceNo NVARCHAR(50)  = NULL,
    @ItemId              INT           = NULL,
    @BlNo                NVARCHAR(30)  = NULL,
    @Status              TINYINT       = NULL,
    @PortId              INT           = NULL,
    @WarehouseId         INT           = NULL,
    @BranchId            INT           = NULL,
    @OrderMonthKey       INT           = NULL,   -- e.g. 202601
    @DateFrom            DATE          = NULL,   -- order date
    @DateTo              DATE          = NULL,
    @SortColumn          NVARCHAR(30)  = N'OrderDate',  -- ContainerRef | ContainerNo | OrderDate | DispatchDate | Eta | Status | CreatedAtUtc
    @SortDirection       NVARCHAR(4)   = N'DESC',
    @PageNumber          INT           = 1,
    @PageSize            INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @ContainerRef = NULLIF(LTRIM(RTRIM(@ContainerRef)), N'');
    SET @ContainerNo = NULLIF(LTRIM(RTRIM(@ContainerNo)), N'');
    SET @CommercialInvoiceNo = NULLIF(LTRIM(RTRIM(@CommercialInvoiceNo)), N'');
    SET @BlNo = NULLIF(LTRIM(RTRIM(@BlNo)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ContainerRef', N'ContainerNo', N'OrderDate', N'DispatchDate', N'Eta', N'Status', N'CreatedAtUtc')
        SET @SortColumn = N'OrderDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT c.Id, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, ct.TypeName AS ContainerTypeName,
           c.OrderDate, c.OrderMonthKey,
           OrderMonth = FORMAT(c.OrderDate, N'MMM-yyyy', N'en-US'),
           c.BranchId, b.BranchCode, b.BranchName, c.WarehouseId, w.WarehouseCode, w.WarehouseName,
           SupplierCount = ISNULL(inv.SupplierCount, 0),
           SupplierNames = CASE WHEN ISNULL(inv.SupplierCount, 0) = 0 THEN NULL
                                WHEN inv.SupplierCount = 1 THEN inv.FirstSupplier
                                ELSE inv.FirstSupplier + N' +' + CAST(inv.SupplierCount - 1 AS NVARCHAR(10)) END,
           InvoiceCount = ISNULL(inv.InvoiceCount, 0),
           InvoiceNumbers = CASE WHEN ISNULL(inv.InvoiceCount, 0) = 0 THEN NULL
                                 WHEN inv.InvoiceCount = 1 THEN inv.FirstInvoice
                                 ELSE inv.FirstInvoice + N' +' + CAST(inv.InvoiceCount - 1 AS NVARCHAR(10)) END,
           CommercialInvoiceNos = CASE WHEN inv.CiCount = 1 THEN inv.FirstCi
                                       WHEN inv.CiCount > 1 THEN inv.FirstCi + N' +' + CAST(inv.CiCount - 1 AS NVARCHAR(10)) END,
           ItemCount = ISNULL(ln.ItemCount, 0),
           ItemSummary = CASE WHEN ISNULL(ln.ItemCount, 0) = 0 THEN NULL
                              WHEN ln.ItemCount = 1 THEN ln.FirstItem
                              ELSE N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           TotalQtyBase = ISNULL(ln.Qty, 0), TotalReceivedBase = c.TotalReceivedBase, c.TotalOilQty,
           c.MaxUnits, c.UtilizationPct,
           c.BlNo, c.BlDate, c.DispatchDate, c.Eta, c.ActualPortArrival, c.CustomsReleaseDate, c.OffloadedDate,
           c.FreeDays, c.LastFreeDay,
           DaysAtPort = CASE WHEN c.ActualPortArrival IS NOT NULL
                             THEN DATEDIFF(DAY, c.ActualPortArrival, ISNULL(c.OffloadedDate, CAST(SYSUTCDATETIME() AS DATE))) END,
           c.CurrentLocation, c.Status, c.StatusNote,
           pl.PortName AS PortOfLoadingName, pd.PortName AS PortOfDestinationName,
           c.CreatedAtUtc, c.CreatedBy, cu.FullName AS CreatedByName, c.UpdatedAtUtc, c.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM logistics.Containers c
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN security.Users cu            ON cu.Id = c.CreatedBy
    OUTER APPLY (SELECT InvoiceCount = COUNT(*), SupplierCount = COUNT(DISTINCT d.SupplierId),
                        CiCount = COUNT(d.CommercialInvoiceNo),
                        FirstInvoice = MIN(d.DocumentNumber), FirstSupplier = MIN(sp.PartyName), FirstCi = MIN(d.CommercialInvoiceNo)
                 FROM logistics.ContainerInvoices ci
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = ci.PurchaseDocumentId
                 INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
                 WHERE ci.ContainerId = c.Id) inv
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), Qty = SUM(cl.QuantityBase), FirstItem = MIN(i.ItemName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 WHERE cl.ContainerId = c.Id) ln
    WHERE (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
           OR c.BlNo LIKE N'%' + @Search + N'%' OR c.VesselName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM logistics.ContainerInvoices ci INNER JOIN purchase.PurchaseDocuments d ON d.Id = ci.PurchaseDocumentId
                      INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
                      WHERE ci.ContainerId = c.Id AND (d.DocumentNumber LIKE N'%' + @Search + N'%'
                            OR d.CommercialInvoiceNo LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%')))
      AND (@ContainerRef IS NULL OR c.ContainerRef LIKE N'%' + @ContainerRef + N'%')
      AND (@ContainerNo IS NULL OR c.ContainerNo LIKE N'%' + @ContainerNo + N'%')
      AND (@BlNo IS NULL OR c.BlNo LIKE N'%' + @BlNo + N'%')
      AND (@Status IS NULL OR c.Status = @Status)
      AND (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR c.WarehouseId = @WarehouseId)
      AND (@PortId IS NULL OR c.PortOfLoadingId = @PortId OR c.PortOfDestinationId = @PortId OR c.FinalDestinationId = @PortId)
      AND (@OrderMonthKey IS NULL OR c.OrderMonthKey = @OrderMonthKey)
      AND (@DateFrom IS NULL OR c.OrderDate >= @DateFrom)
      AND (@DateTo IS NULL OR c.OrderDate <= @DateTo)
      AND (@SupplierId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerInvoices ci INNER JOIN purchase.PurchaseDocuments d ON d.Id = ci.PurchaseDocumentId
                                          WHERE ci.ContainerId = c.Id AND d.SupplierId = @SupplierId))
      AND (@PurchaseDocumentId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerInvoices ci WHERE ci.ContainerId = c.Id AND ci.PurchaseDocumentId = @PurchaseDocumentId))
      AND (@CommercialInvoiceNo IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerInvoices ci INNER JOIN purchase.PurchaseDocuments d ON d.Id = ci.PurchaseDocumentId
                                                   WHERE ci.ContainerId = c.Id AND d.CommercialInvoiceNo LIKE N'%' + @CommercialInvoiceNo + N'%'))
      AND (@ItemId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.ItemId = @ItemId))
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ContainerNo' THEN c.ContainerNo END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ContainerNo' THEN c.ContainerNo END END DESC,
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'OrderDate' THEN c.OrderDate WHEN N'DispatchDate' THEN c.DispatchDate WHEN N'Eta' THEN c.Eta END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'OrderDate' THEN c.OrderDate WHEN N'DispatchDate' THEN c.DispatchDate WHEN N'Eta' THEN c.Eta END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(c.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(c.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END DESC,
        c.OrderDate DESC, c.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

