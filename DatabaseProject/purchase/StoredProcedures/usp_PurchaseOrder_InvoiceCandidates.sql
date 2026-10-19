/* ================================================================== 1. The lines of an order still to invoice */

-- What "Create Purchase Invoice" offers on an order, line by line (the containers' dialog reads
-- logistics.usp_Container_InvoiceCandidates the same way). Available is what usp_PurchaseDocument_CreateFromSource lets
-- a selection take from the line: ordered - invoiced by posted invoices - in draft invoices.
CREATE   PROCEDURE purchase.usp_PurchaseOrder_InvoiceCandidates
    @PurchaseOrderId INT,
    @IncludeAll      BIT = 0      -- 1 = also the lines with nothing left to invoice
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d
                   INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                   WHERE d.Id = @PurchaseOrderId AND dt.Code = N'PO')
        THROW 65006, 'Purchase order not found.', 1;

    SELECT LineId = l.Id, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName,
           OrderedBase   = l.QuantityBase,
           InvoicedBase  = l.ReceivedQuantityBase,
           InDraftsBase  = ISNULL(dr.Qty, 0),
           AvailableBase = CASE WHEN av.Available > 0 THEN av.Available ELSE 0 END
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN inventory.Items i       ON i.Id = l.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 INNER JOIN inventory.DocumentTypes xt ON xt.Id = xd.DocumentTypeId
                 WHERE x.SourceLineId = l.Id AND xd.Status = 1 AND xt.Code = N'PINV') dr
    CROSS APPLY (SELECT Available = l.QuantityBase - l.ReceivedQuantityBase - ISNULL(dr.Qty, 0)) av
    WHERE l.DocumentId = @PurchaseOrderId
      AND (@IncludeAll = 1 OR av.Available > 0)
    ORDER BY l.LineNumber;
END

GO

