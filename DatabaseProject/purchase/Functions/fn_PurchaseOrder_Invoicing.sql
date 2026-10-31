/* ================================================================== 1. How far the posted invoices cover an order */

-- One row for a purchase order (none for an invoice or a return): ordered and invoiced pieces over its lines, and
-- InvoicingStatus 0 not invoiced (Saved), 1 partially (Partially posted), 2 fully (Posted). Invoiced = the lines'
-- ReceivedQuantityBase, raised by a posted invoice and lowered by its cancellation (its old name: it has always meant
-- invoiced). The formula of usp_PurchaseDocument_Get / _Search since script 26, in one place.
CREATE   FUNCTION purchase.fn_PurchaseOrder_Invoicing (@PurchaseOrderId INT)
RETURNS TABLE
AS
RETURN
    SELECT PurchaseOrderId = d.Id,
           OrderedBase     = p.Ordered,
           InvoicedBase    = p.Invoiced,
           InvoicingStatus = CAST(CASE WHEN p.Invoiced = 0 THEN 0 WHEN p.Invoiced >= p.Ordered THEN 2 ELSE 1 END AS TINYINT)
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
    CROSS APPLY (SELECT Ordered  = ISNULL(SUM(l.QuantityBase), 0),
                        Invoiced = ISNULL(SUM(l.ReceivedQuantityBase), 0)
                 FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = d.Id) p
    WHERE d.Id = @PurchaseOrderId;

GO

