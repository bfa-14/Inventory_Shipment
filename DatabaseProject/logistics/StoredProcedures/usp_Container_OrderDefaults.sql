/* ================================================================== 6. What the container dialogs fill in by themselves */

-- (78) NEW. One row for a purchase order: what Auto-plan containers... and Add Container... start with.
--   Supplier*        the order's supplier, shown read-only: a container's goods come from its order lines, so its
--                    supplier is never typed.
--   Forwarder*       the forwarder of the order's most recent container (not cancelled) that has an active one, else
--                    the order's supplier (ForwarderSource LastContainer | Supplier). The dialog keeps it editable.
--   CountryOfOrigin  the supplier's country (ISO 3166-1 alpha-2), NULL when the supplier has none.
-- No row when the id is not a purchase order.
CREATE   PROCEDURE logistics.usp_Container_OrderDefaults
    @PurchaseOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT PurchaseOrderId     = d.Id,
           PurchaseOrderNumber = d.DocumentNumber,
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

