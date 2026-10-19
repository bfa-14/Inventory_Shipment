--   - what each order line still allows: what the order line committed outside containers is
--     purchase.fn_PoLine_CommittedOutside(order line, this invoice) - the larger of what the OTHER invoices invoiced and
--     what is received (or on draft goods receipts) outside containers - in place of the "dir" subquery (invoiced only);
--   - rule 4 on an invoice posted after the switch (UsesGoodsReceipts = 1) without "Shipped in containers": its goods
--     are received with Receive goods..., not with containers (the old sentence stays for invoices posted before); the
--     draft's hint no longer names the retired container offload, and rule 7 names the received pieces too;
--   - rule 6 also when a GOODS RECEIPT refers to the invoice's lines outside containers (rule 28): pieces of them were
--     received (a posted receipt matched to them - pass 2 matches an unlinked "Shipped in containers" line to the goods
--     of the order's containers as they are received - or returned), or a draft or posted receipt was made from them.
--     Linking would split or move such a line, which usp_PurchaseInvoice_LinkContainers refuses (65028, naming the line
--     and its receipt, ahead of this rule): so the card disables Link / Add / Auto-plan with the reason, and
--     usp_PurchaseInvoice_CheckContainers refuses Add and Auto-plan up front (65030). Document-wide, as the "already
--     received" refusal of LinkContainers is.
-- (63) rule 3 (a draft of several items is split by item first) only for an invoice whose mode is one item.
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
                   OUTER APPLY purchase.fn_PoLine_CommittedOutside(pol.Id, d.Id) dir     -- (65) invoiced by the others, or received, outside containers
                   CROSS APPLY (SELECT Qty = pol.QuantityBase
                                    - ISNULL(dir.Qty, 0)
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
-- (63) the invoice's mode: rule 3 (split a draft of several items first) concerns a one-item invoice only
CROSS APPLY (SELECT OneItemOnly = COALESCE(d.OneItemOnly, configuration.fn_SettingBool(N'Purchase.OneItemPerInvoice'))) oi
-- (65) rule 28: the first goods receipt that refers to a line of the invoice outside containers (the posted one first;
--      Found = 1 also for pieces received or returned on such a line without a receipt to name; Status 2 posted, 1 draft)
OUTER APPLY (SELECT TOP (1) Found = 1, gr.Status, Number = gr.DocumentNumber
             FROM purchase.PurchaseDocumentLines x
             OUTER APPLY (SELECT TOP (1) r.Status, r.DocumentNumber, r.Id
                          FROM (SELECT g.Id, g.Status, g.DocumentNumber          -- a receipt made from the line, draft or posted
                                FROM purchase.GoodsReceiptLines gl
                                INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId
                                WHERE gl.InvoiceLineId = x.Id AND g.Status < 3
                                UNION ALL
                                SELECT g.Id, g.Status, g.DocumentNumber          -- a posted receipt whose pieces are matched to it
                                FROM purchase.GoodsReceiptInvoiceMatches m
                                INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = m.GoodsReceiptLineId
                                INNER JOIN purchase.GoodsReceipts g      ON g.Id = gl.GoodsReceiptId
                                WHERE m.InvoiceLineId = x.Id AND g.Status = 2) r
                          ORDER BY r.Status DESC, r.Id) gr
             WHERE x.DocumentId = d.Id AND x.ContainerLineId IS NULL AND x.SourceLineId IS NOT NULL
               AND (gr.Status IS NOT NULL OR x.ReceivedQuantityBase > 0 OR x.ReturnedQuantityBase > 0)
             ORDER BY CASE WHEN gr.Status = 2 THEN 0 WHEN gr.Status = 1 THEN 1 ELSE 2 END, x.LineNumber) grn
CROSS APPLY (SELECT FailedRule = CAST(CASE
                        WHEN dt.Code <> N'PINV' OR d.Status NOT IN (1, 2) THEN 1
                        WHEN o.Id IS NULL OR ot.Code <> N'PO' OR ln.Typed > 0 THEN 2
                        WHEN ln.ItemCount > 1 AND d.Status = 1 AND oi.OneItemOnly = 1 THEN 3
                        WHEN d.ReceiptMode <> 2 THEN 4
                        WHEN o.Status NOT IN (2, 4) THEN 5
                        WHEN grn.Found = 1 THEN 6
                        WHEN ISNULL(u.NotInContainer, 0) = 0 THEN 6
                        WHEN ISNULL(u.Available, 0) = 0 THEN 7 END AS TINYINT),
                    Reason = CAST(CASE
                        WHEN dt.Code <> N'PINV' THEN N'Only a purchase invoice can take containers.'
                        WHEN d.Status NOT IN (1, 2) THEN N'A cancelled invoice cannot be linked to containers.'
                        WHEN o.Id IS NULL OR ot.Code <> N'PO' OR ln.Typed > 0
                            THEN N'Only a purchase invoice created from a purchase order can be linked to containers.'
                        WHEN ln.ItemCount > 1 AND d.Status = 1 AND oi.OneItemOnly = 1
                            THEN N'This invoice holds ' + CAST(ln.ItemCount AS NVARCHAR(10))
                                 + N' items and a supplier invoice holds one: split it by item first.'
                        WHEN d.ReceiptMode <> 2 AND d.Status = 1
                            THEN N'Turn on "Shipped in containers" first: the goods will then enter the stock when their containers are received.'
                        WHEN d.ReceiptMode <> 2 AND d.UsesGoodsReceipts = 1
                            THEN N'This invoice was posted without "Shipped in containers": its goods are received with Receive goods' + NCHAR(8230) + N', not with containers.'
                        WHEN d.ReceiptMode <> 2 THEN N'This invoice was received when it was posted: it cannot be linked to containers.'
                        WHEN o.Status NOT IN (2, 4)
                            THEN N'Order ' + ISNULL(o.DocumentNumber, N'(draft)') + N' is '
                                 + CASE o.Status WHEN 1 THEN N'a draft' WHEN 3 THEN N'cancelled' ELSE N'waiting for approval' END
                                 + N': containers are made from an approved order.'
                        WHEN ln.Lines = 0 THEN N'This invoice has no lines yet.'
                        WHEN grn.Status = 2
                            THEN N'Goods receipt ' + grn.Number + N' already received pieces of this invoice that are not in a container: '
                                 + N'its lines can no longer be linked to containers. The rest is matched to the goods of the order''s '
                                 + N'containers when they are received.'
                        WHEN grn.Status = 1
                            THEN N'A draft goods receipt was made from this invoice: delete it before linking the invoice to containers.'
                        WHEN grn.Found = 1
                            THEN N'Goods of this invoice outside containers were already received or returned: it can no longer be linked to containers.'
                        WHEN ISNULL(u.NotInContainer, 0) = 0 THEN N'Every piece of this invoice is already in a container.'
                        WHEN ISNULL(u.Available, 0) = 0
                            THEN N'Order ' + o.DocumentNumber + N' allows no more pieces: its lines are already loaded in containers'
                                 + N', or invoiced or received outside containers.' END AS NVARCHAR(400))) r
WHERE d.Id = @InvoiceId;

GO

