SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 121: LOGISTICS - AUTO-PLAN STARTS AT THE PURCHASE ORDER'S DATE

   The owner: "In purchase invoice at auto plan to create container, order date must be as purchase order date".
   The Auto-plan dialog (on a purchase invoice and on a purchase order: one dialog) started its "Order date" - the
   Order date every container of the plan gets, and its Order Month - at today. It now starts at the date of the
   purchase order the containers are created from; the user may still change it before creating them.

     logistics.usp_Container_OrderDefaults (@PurchaseOrderId)      (from script 78)
        + OrderDate = the order's document date, beside the supplier, the forwarder and the country of origin the
          dialogs already take from it. Nothing else changes.

   No table, column, permission or error number. Requires script 78. Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'logistics.usp_Container_OrderDefaults', N'P') IS NULL
    THROW 50000, 'Script 121 requires script 78: apply it first.', 1;
GO

/* ================================================================== 1. logistics.usp_Container_OrderDefaults (from script 78) */

CREATE OR ALTER PROCEDURE logistics.usp_Container_OrderDefaults
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

/* ================================================================== 2. Check */

-- The newest approved orders and the date their containers start with.
SELECT TOP (5) d.Id, d.DocumentNumber, OrderDate = d.DocumentDate
FROM purchase.PurchaseDocuments d
INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
WHERE d.Status = 2
ORDER BY d.Id DESC;

PRINT 'Script 121 applied: Auto-plan starts the containers'' Order date at the purchase order''s date (usp_Container_OrderDefaults).';
GO
