CREATE   PROCEDURE logistics.usp_Container_AvailableInvoices
    @Search      NVARCHAR(100) = NULL,
    @SupplierId  INT           = NULL,
    @ContainerId INT           = NULL,     -- excluded from "allocated elsewhere"
    @Top         INT           = 50
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @Top IS NULL OR @Top < 1 SET @Top = 50;

    SELECT TOP (@Top)
           d.Id, d.DocumentNumber, d.DocumentDate, d.Status, d.ReceiptMode,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, c.CurrencyCode, c.Symbol AS CurrencySymbol,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo,
           d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           TotalQtyBase     = x.Total,
           AllocatedBase    = ISNULL(x.Allocated, 0),
           AllocatedHereBase = ISNULL(x.Here, 0),
           RemainingBase    = x.Total - ISNULL(x.Allocated, 0),
           d.TotalAmount, d.TotalAmountBase
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    CROSS APPLY (SELECT Total = ISNULL(SUM(l.QuantityBase), 0),
                        Allocated = ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                                            INNER JOIN logistics.Containers ct ON ct.Id = cl.ContainerId
                                            WHERE cl.PurchaseDocumentId = d.Id AND ct.Status <> 8), 0),
                        Here = ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                                       WHERE cl.PurchaseDocumentId = d.Id AND cl.ContainerId = @ContainerId), 0)
                 FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = d.Id) x
    WHERE dt.Code = N'PINV'
      AND d.Status IN (1, 2)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.CommercialInvoiceNo LIKE N'%' + @Search + N'%'
           OR d.SupplierReference LIKE N'%' + @Search + N'%' OR d.ExporterReference LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%')
      AND (x.Total - ISNULL(x.Allocated, 0) > 0 OR ISNULL(x.Here, 0) > 0)
    ORDER BY d.DocumentDate DESC, d.Id DESC;
END

GO

