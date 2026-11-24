/* ================================================================== 1. logistics.usp_Container_OrderDefaults (from script 78) */

CREATE   PROCEDURE logistics.usp_Container_OrderDefaults
    @PurchaseOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT PurchaseOrderId     = d.Id,
           PurchaseOrderNumber = d.DocumentNumber,
           OrderDate           = d.DocumentDate,                    -- (121) what the containers' Order date starts as
           SupplierId          = s.Id,
           SupplierCode        = s.PartyCode,
           SupplierName        = s.PartyName,
           CountryOfOrigin     = CAST(NULLIF(UPPER(LTRIM(RTRIM(s.Country))), N'') AS NCHAR(2)),
           ForwarderId         = f.Id,
           ForwarderCode       = f.PartyCode,
           ForwarderName       = f.PartyName,
           ForwarderSource     = CAST(CASE WHEN lc.ForwarderId IS NOT NULL THEN N'LastContainer' ELSE N'Supplier' END AS NVARCHAR(20)),
           LastContainerRef    = lc.ContainerRef
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
    INNER JOIN masterdata.Parties s       ON s.Id = d.SupplierId
    OUTER APPLY (SELECT TOP (1) c.ForwarderId, c.ContainerRef
                 FROM logistics.Containers c
                 INNER JOIN masterdata.Parties p ON p.Id = c.ForwarderId AND p.IsActive = 1
                 WHERE c.PurchaseOrderId = d.Id AND c.Status <> 8
                 ORDER BY c.Id DESC) lc
    INNER JOIN masterdata.Parties f       ON f.Id = ISNULL(lc.ForwarderId, s.Id)
    WHERE d.Id = @PurchaseOrderId;
END

GO

