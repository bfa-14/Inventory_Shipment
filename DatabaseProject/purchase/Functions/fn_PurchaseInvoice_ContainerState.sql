/* ================================================================== 1. The rules, in one place */

-- One row per invoice: its figures and the first rule (1-7) it fails. Rule 8 needs a quantity: the check compares it
-- with MaxAddQty. The figures leave the invoice's own lines out of "invoiced outside containers", so a draft with the
-- switch off already shows what it could take once turned on.
CREATE   FUNCTION purchase.fn_PurchaseInvoice_ContainerState (@InvoiceId INT)
RETURNS TABLE
AS
RETURN
SELECT d.Id AS InvoiceId, d.DocumentNumber, d.Status, d.ReceiptMode,
       OrderId = o.Id, OrderNo = o.DocumentNumber, OrderStatus = o.Status,
       ln.ItemCount, ItemId = CASE WHEN ln.ItemCount = 1 THEN ln.FirstItemId END,
       NotInContainerQty      = ISNULL(u.NotInContainer, 0),
       OrderLinesAvailableQty = ISNULL(u.Available, 0),
       MaxAddQty              = ISNULL(u.MaxAdd, 0),
       pc.PcsPerContainer,
       LinkableQty            = ISNULL(k.Qty, 0),
       r.FailedRule, r.Reason,
       CanAddContainers = CAST(CASE WHEN r.FailedRule IS NULL THEN 1 ELSE 0 END AS BIT),
       CanTurnOnShipped = CAST(CASE WHEN r.FailedRule = 4 AND d.Status = 1 THEN 1 ELSE 0 END AS BIT),
       CanLink          = CAST(CASE WHEN ISNULL(r.FailedRule, 7) = 7 AND ISNULL(k.Qty, 0) > 0 THEN 1 ELSE 0 END AS BIT),
       LinkReason       = CAST(CASE WHEN ISNULL(r.FailedRule, 7) <> 7 THEN r.Reason
                                    WHEN ISNULL(k.Qty, 0) = 0
                                        THEN N'No container of order ' + ISNULL(o.DocumentNumber, N'(draft)')
                                             + N' has pieces left to link: add a container.' END AS NVARCHAR(400))
FROM purchase.PurchaseDocuments d
INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
LEFT  JOIN purchase.PurchaseDocuments o ON o.Id = d.SourceDocumentId
LEFT  JOIN inventory.DocumentTypes ot   ON ot.Id = o.DocumentTypeId
CROSS APPLY (SELECT Lines = COUNT(*), ItemCount = COUNT(DISTINCT l.ItemId), FirstItemId = MIN(l.ItemId),
                    Typed = SUM(CASE WHEN l.SourceLineId IS NULL THEN 1 ELSE 0 END)
             FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = d.Id) ln
-- per order line the invoice has pieces of outside containers: those pieces, and what the order line still allows
OUTER APPLY (SELECT NotInContainer = SUM(x.Unlinked), Available = SUM(x.Allowed),
                    MaxAdd = SUM(CASE WHEN x.Unlinked < x.Allowed THEN x.Unlinked ELSE x.Allowed END)
             FROM (SELECT Unlinked = un.UnlinkedBase,
                          Allowed = CASE WHEN a.Qty > 0 THEN a.Qty ELSE 0 END
                   FROM purchase.fn_PurchaseInvoice_Unlinked(d.Id) un
                   INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = un.PoLineId
                   CROSS APPLY (SELECT Qty = pol.QuantityBase
                                    - ISNULL((SELECT SUM(dl.QuantityBase) FROM purchase.PurchaseDocumentLines dl
                                              INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = dl.DocumentId
                                              WHERE dl.SourceLineId = pol.Id AND dl.ContainerLineId IS NULL AND dl.DocumentId <> d.Id
                                                AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2), 0)
                                    - ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                                              INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                                              WHERE cl.PoLineId = pol.Id AND c.Status <> 8), 0)) a) x) u
OUTER APPLY (SELECT PcsPerContainer = MAX(s.PcsPerContainer) FROM purchase.fn_PurchaseInvoice_ItemContainers(d.Id) s) pc
-- what the order's Draft / Confirmed containers have loaded and not invoiced yet, on the order lines the invoice has outside
OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase - ISNULL(q.Qty, 0))
             FROM logistics.ContainerLines cl
             INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
             OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                          INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                          WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
             WHERE cl.PurchaseOrderId = o.Id AND c.Status IN (1, 2) AND cl.QuantityBase - ISNULL(q.Qty, 0) > 0
               AND cl.PoLineId IN (SELECT PoLineId FROM purchase.fn_PurchaseInvoice_Unlinked(d.Id))) k
CROSS APPLY (SELECT FailedRule = CAST(CASE
                        WHEN dt.Code <> N'PINV' OR d.Status NOT IN (1, 2) THEN 1
                        WHEN o.Id IS NULL OR ot.Code <> N'PO' OR ln.Typed > 0 THEN 2
                        WHEN ln.ItemCount > 1 AND d.Status = 1 THEN 3
                        WHEN d.ReceiptMode <> 2 THEN 4
                        WHEN o.Status NOT IN (2, 4) THEN 5
                        WHEN ISNULL(u.NotInContainer, 0) = 0 THEN 6
                        WHEN ISNULL(u.Available, 0) = 0 THEN 7 END AS TINYINT),
                    Reason = CAST(CASE
                        WHEN dt.Code <> N'PINV' THEN N'Only a purchase invoice can take containers.'
                        WHEN d.Status NOT IN (1, 2) THEN N'A cancelled invoice cannot be linked to containers.'
                        WHEN o.Id IS NULL OR ot.Code <> N'PO' OR ln.Typed > 0
                            THEN N'Only a purchase invoice created from a purchase order can be linked to containers.'
                        WHEN ln.ItemCount > 1 AND d.Status = 1
                            THEN N'This invoice holds ' + CAST(ln.ItemCount AS NVARCHAR(10))
                                 + N' items and a supplier invoice holds one: split it by item first.'
                        WHEN d.ReceiptMode <> 2 AND d.Status = 1
                            THEN N'Turn on "Shipped in containers" first: the goods will then enter the stock at the container offload.'
                        WHEN d.ReceiptMode <> 2 THEN N'This invoice was received when it was posted: it cannot be linked to containers.'
                        WHEN o.Status NOT IN (2, 4)
                            THEN N'Order ' + ISNULL(o.DocumentNumber, N'(draft)') + N' is '
                                 + CASE o.Status WHEN 1 THEN N'a draft' WHEN 3 THEN N'cancelled' ELSE N'waiting for approval' END
                                 + N': containers are made from an approved order.'
                        WHEN ln.Lines = 0 THEN N'This invoice has no lines yet.'
                        WHEN ISNULL(u.NotInContainer, 0) = 0 THEN N'Every piece of this invoice is already in a container.'
                        WHEN ISNULL(u.Available, 0) = 0
                            THEN N'Order ' + o.DocumentNumber + N' allows no more pieces: its lines are already loaded in containers'
                                 + N' or invoiced outside containers.' END AS NVARCHAR(400))) r
WHERE d.Id = @InvoiceId;

GO

