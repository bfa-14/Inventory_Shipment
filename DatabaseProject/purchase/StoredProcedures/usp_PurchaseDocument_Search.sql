/* ================================================================== 7. Search: the item of a supplier invoice */

-- Re-created (45) from its current body (status 5, invoicing): the item of a supplier invoice, and its code in the search.
CREATE   PROCEDURE purchase.usp_PurchaseDocument_Search
    @DocumentTypeCode NVARCHAR(20) = NULL,     -- PO | PINV | PRET | NULL = whole family
    @Search           NVARCHAR(100) = NULL,    -- number, supplier / exporter reference, commercial invoice no., supplier code/name, notes,
                                               -- (45) the item code of a supplier invoice
    @BranchId         INT          = NULL,
    @WarehouseId      INT          = NULL,
    @SupplierId       INT          = NULL,
    @Status           TINYINT      = NULL,     -- 1 Draft | 2 Posted (PO: approved) | 3 Cancelled | 4 Closed | 5 Pending approval
    @InvoicingStatus  TINYINT      = NULL,     -- purchase orders: 0 not invoiced | 1 partially | 2 fully
    @DateFrom         DATE         = NULL,
    @DateTo           DATE         = NULL,
    @SortColumn       NVARCHAR(30) = N'DocumentDate',  -- DocumentNumber | DocumentDate | SupplierName | Status | TotalAmount | CreatedAtUtc
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
    SET @DocumentTypeCode = NULLIF(LTRIM(RTRIM(@DocumentTypeCode)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'DocumentNumber', N'DocumentDate', N'SupplierName', N'Status', N'TotalAmount', N'CreatedAtUtc')
        SET @SortColumn = N'DocumentDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT d.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate, d.BranchId, b.BranchName, d.WarehouseId, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, c.CurrencyCode, c.Symbol AS CurrencySymbol, c.DecimalPlaces, d.ExchangeRate,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo, d.ReceiptMode,
           d.Status, d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber,
           ReceivedPercent = CASE WHEN dt.Code = N'PO' AND ISNULL(prog.Ordered, 0) > 0 THEN CAST(100.0 * prog.Invoiced / prog.Ordered AS DECIMAL(5,1)) END,
           InvoicedPercent = CASE WHEN dt.Code = N'PO' AND ISNULL(prog.Ordered, 0) > 0 THEN CAST(100.0 * prog.Invoiced / prog.Ordered AS DECIMAL(5,1)) END,
           InvoicingStatus = CASE WHEN dt.Code <> N'PO' THEN NULL WHEN ISNULL(prog.Invoiced, 0) = 0 THEN 0
                                  WHEN prog.Invoiced >= prog.Ordered THEN 2 ELSE 1 END,
           DraftInvoiceCount = CASE WHEN dt.Code = N'PO' THEN (SELECT COUNT(*) FROM purchase.PurchaseDocuments x WHERE x.SourceDocumentId = d.Id AND x.Status = 1) END,
           -- (45) the item of a supplier invoice (the one of its first line) and how many it holds (more than 1: made before 45)
           ItemId = itm.ItemId, ItemCode = itm.ItemCode, ItemName = itm.ItemName, ItemCount = itm.ItemCount,
           d.ApprovalRequestedAtUtc, d.ApprovedAtUtc, apu.FullName AS ApprovedByName,
           d.PostedAtUtc, pu.FullName AS PostedByName, d.CancelledAtUtc, d.ClosedAtUtc,
           d.CreatedAtUtc, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users apu ON apu.Id = d.ApprovedBy
    OUTER APPLY (SELECT Ordered = SUM(QuantityBase), Invoiced = SUM(ReceivedQuantityBase)
                 FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id) prog
    OUTER APPLY (SELECT TOP (1) fl.ItemId, fi.ItemCode, fi.ItemName,
                        ItemCount = (SELECT COUNT(DISTINCT ItemId) FROM purchase.PurchaseDocumentLines WHERE DocumentId = d.Id)
                 FROM purchase.PurchaseDocumentLines fl INNER JOIN inventory.Items fi ON fi.Id = fl.ItemId
                 WHERE fl.DocumentId = d.Id AND dt.Code = N'PINV'
                 ORDER BY fl.LineNumber) itm
    WHERE dt.Family = N'Purchase'
      AND (@DocumentTypeCode IS NULL OR dt.Code = @DocumentTypeCode)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.SupplierReference LIKE N'%' + @Search + N'%'
           OR d.ExporterReference LIKE N'%' + @Search + N'%' OR d.CommercialInvoiceNo LIKE N'%' + @Search + N'%'
           OR sp.PartyCode LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%' OR d.Notes LIKE N'%' + @Search + N'%'
           OR (dt.Code = N'PINV' AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines sl INNER JOIN inventory.Items si ON si.Id = sl.ItemId
                                             WHERE sl.DocumentId = d.Id AND si.ItemCode LIKE N'%' + @Search + N'%')))
      AND (@BranchId IS NULL OR d.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR d.WarehouseId = @WarehouseId)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Status IS NULL OR d.Status = @Status)
      AND (@InvoicingStatus IS NULL OR (dt.Code = N'PO' AND
           CASE WHEN ISNULL(prog.Invoiced, 0) = 0 THEN 0 WHEN prog.Invoiced >= prog.Ordered THEN 2 ELSE 1 END = @InvoicingStatus))
      AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'SupplierName' THEN sp.PartyName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'DocumentNumber' THEN d.DocumentNumber WHEN N'SupplierName' THEN sp.PartyName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'DocumentDate' THEN d.DocumentDate END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(d.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'TotalAmount' THEN d.TotalAmount END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'TotalAmount' THEN d.TotalAmount END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN d.CreatedAtUtc END DESC,
        d.DocumentDate DESC, d.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END

GO

