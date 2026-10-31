/* ================================================================== 9. Goods receipt: why it cannot be posted */

-- Re-created (72) from the body of script 64: rows 6 and 7 also refuse a warehouse with warehouses under it - a draft
-- saved before this script. usp_GoodsReceipt_Post raises the first row (Post itself is unchanged), usp_GoodsReceipt_Get
-- shows it, so the page and the refusal say the same sentence.
CREATE   FUNCTION purchase.fn_GoodsReceipt_PostCheck (@Id INT)
RETURNS TABLE
AS
RETURN
WITH h AS
(
    SELECT g.Id, g.Status, g.SourceKind, g.ContainerId, g.SupplierId, g.WarehouseId, g.DocumentDate,
           c.ContainerRef, CtStatus = c.Status, CtBranchId = c.BranchId
    FROM purchase.GoodsReceipts g
    LEFT JOIN logistics.Containers c ON c.Id = g.ContainerId
    WHERE g.Id = @Id
),
l AS
(
    SELECT gl.Id, gl.LineNumber, gl.ItemId, gl.QuantityBase, gl.ExpectedQuantityBase, gl.VarianceReasonCode, gl.VarianceReason,
           gl.CloseShort, gl.PoLineId, gl.PurchaseOrderId, gl.InvoiceLineId, gl.ContainerLineId,
           i.ItemCode, ItemActive = i.IsActive,
           WarehouseId = CASE WHEN h.SourceKind = N'Container' THEN h.WarehouseId ELSE COALESCE(gl.WarehouseId, h.WarehouseId) END,
           Tag = N'Line ' + CAST(gl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N')'
    FROM h
    INNER JOIN purchase.GoodsReceiptLines gl ON gl.GoodsReceiptId = h.Id
    INNER JOIN inventory.Items i             ON i.Id = gl.ItemId
)
SELECT x.Seq, x.ErrorNumber, x.Message
FROM
(
    SELECT Seq = 1, ErrorNumber = 63006, Message = CAST(N'Goods receipt not found.' AS NVARCHAR(400))
    WHERE NOT EXISTS (SELECT 1 FROM h)

    UNION ALL
    SELECT 2, 63010, N'Only a draft goods receipt can be posted.' FROM h WHERE h.Status <> 1

    UNION ALL
    SELECT 3, 63009, N'The goods receipt has no lines.' FROM h WHERE NOT EXISTS (SELECT 1 FROM l)

    UNION ALL
    SELECT 4, 63000, N'Choose the warehouse the goods are received into.'
    FROM h WHERE h.SourceKind = N'Container' AND h.WarehouseId IS NULL

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 5, ErrorNumber = 63000, Message = l.Tag + N': choose the warehouse the goods are received into.'
                   FROM l WHERE l.WarehouseId IS NULL AND l.ContainerLineId IS NULL ORDER BY l.LineNumber) a

    UNION ALL
    -- (72) + at the bottom of the tree (script 70): a draft saved before it, or a warehouse that got warehouses under it
    SELECT 6, 63000, CASE WHEN w.IsActive = 0 OR w.BranchId <> h.CtBranchId
                          THEN N'The warehouse ' + w.WarehouseCode + N' is inactive or does not belong to the branch of container ' + h.ContainerRef + N'.'
                          ELSE N'The warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.' END
    FROM h INNER JOIN masterdata.Warehouses w ON w.Id = h.WarehouseId
    WHERE h.SourceKind = N'Container' AND (w.IsActive = 0 OR w.BranchId <> h.CtBranchId OR masterdata.fn_Warehouse_IsLeaf(w.Id) = 0)

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 7, ErrorNumber = 63000,
                          Message = l.Tag + N': the warehouse ' + w.WarehouseCode
                                    + CASE WHEN w.IsActive = 0 THEN N' is inactive.'
                                           ELSE N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.' END   -- (72) script 70
                   FROM l INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
                   WHERE l.ContainerLineId IS NULL AND (w.IsActive = 0 OR masterdata.fn_Warehouse_IsLeaf(w.Id) = 0)
                   ORDER BY l.LineNumber) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 8, ErrorNumber = 63000,
                          Message = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + l.ItemCode + N' is inactive. Activate it in Item Definition before receiving it.'
                   FROM l WHERE l.ItemActive = 0 ORDER BY l.LineNumber) a

    UNION ALL
    -- one day of tolerance: the date is the reader's local date, compared with a UTC one (usp_PurchaseDocument_ValidateInput)
    SELECT 9, 63000, N'The date received cannot be in the future.'
    FROM h WHERE h.DocumentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))

    UNION ALL
    SELECT 10, 63010, N'Only a confirmed container that is not received yet can be received: ' + h.ContainerRef + N' is '
                      + CASE h.CtStatus WHEN 1 THEN N'a draft' WHEN 6 THEN N'already offloaded' WHEN 7 THEN N'closed'
                                        WHEN 8 THEN N'cancelled' ELSE N'not ready' END + N'.'
    FROM h WHERE h.SourceKind = N'Container' AND (h.CtStatus IS NULL OR h.CtStatus NOT BETWEEN 2 AND 5)

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 11, ErrorNumber = 63010,
                          Message = N'Container ' + h.ContainerRef + N' is travelling with movement ' + m.MovementNo
                                    + N'. Complete it before receiving the goods.'
                   FROM h
                   INNER JOIN logistics.MovementContainers mc ON mc.ContainerId = h.ContainerId
                   INNER JOIN logistics.Movements m           ON m.Id = mc.MovementId AND m.Status = 2
                   WHERE h.SourceKind = N'Container'
                   ORDER BY m.MovementNo) a

    UNION ALL
    -- not before the end of the container's latest completed Delivery (the rule of usp_GoodsReceipt_Save)
    SELECT 12, 63000, N'The goods cannot be received before ' + d.MovementNo + N' reached ' + d.PlaceName
                      + N' on ' + CONVERT(NVARCHAR(10), d.EndDate, 23) + N'.'
    FROM h CROSS APPLY logistics.fn_Container_LastDelivery(h.ContainerId) d
    WHERE h.SourceKind = N'Container' AND h.DocumentDate < d.EndDate

    UNION ALL
    -- the receipt mirrors the container line by line: same lines, items, order lines and loaded pieces
    SELECT 13, 63000, N'The container''s lines changed after this goods receipt was created. Delete it and receive the container again.'
    FROM h
    WHERE h.SourceKind = N'Container'
      AND (EXISTS (SELECT 1 FROM l
                   LEFT JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId AND cl.ContainerId = h.ContainerId
                   WHERE cl.Id IS NULL OR cl.ItemId <> l.ItemId OR cl.PoLineId <> ISNULL(l.PoLineId, -1)
                      OR cl.QuantityBase <> ISNULL(l.ExpectedQuantityBase, -1))
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      WHERE cl.ContainerId = h.ContainerId AND (SELECT COUNT(*) FROM l WHERE l.ContainerLineId = cl.Id) <> 1))

    UNION ALL
    -- a container's goods are received with the container's own receipt only (it updates the container and its costs)
    SELECT * FROM (SELECT TOP (1) Seq = 13, ErrorNumber = 63000,
                          Message = l.Tag + N': goods loaded in a container are received with the goods receipt of that container.'
                   FROM h INNER JOIN l ON l.ContainerLineId IS NOT NULL
                   WHERE h.SourceKind <> N'Container'
                   ORDER BY l.LineNumber) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 14, ErrorNumber = 63000,
                          Message = l.Tag + N': received ' + CAST(l.QuantityBase AS NVARCHAR(20)) + N' but only '
                                    + CAST(l.ExpectedQuantityBase AS NVARCHAR(20)) + N' were loaded.'
                   FROM l WHERE l.ContainerLineId IS NOT NULL AND l.QuantityBase > l.ExpectedQuantityBase
                   ORDER BY l.LineNumber) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 15, ErrorNumber = 63000,
                          Message = CASE WHEN l.ContainerLineId IS NOT NULL
                                         THEN l.Tag + N': choose a reason when the received quantity differs from the loaded quantity.'
                                         ELSE l.Tag + N': give the reason why nothing more will come.' END
                   FROM l
                   WHERE l.VarianceReasonCode IS NULL
                     AND ((l.ContainerLineId IS NOT NULL AND l.QuantityBase <> l.ExpectedQuantityBase)
                          OR (l.ContainerLineId IS NULL AND l.CloseShort = 1 AND NULLIF(LTRIM(RTRIM(l.VarianceReason)), N'') IS NULL))
                   ORDER BY l.LineNumber) a

    UNION ALL
    -- 0 PIECES on a local line only with "Nothing more will come" on a line of an order (usp_GoodsReceipt_Save's rule;
    -- the table only refuses a negative quantity)
    SELECT * FROM (SELECT TOP (1) Seq = 15, ErrorNumber = 63000,
                          Message = l.Tag + N': the received quantity must be more than 0.'
                   FROM l WHERE l.ContainerLineId IS NULL AND l.QuantityBase = 0 AND (l.CloseShort = 0 OR l.PoLineId IS NULL)
                   ORDER BY l.LineNumber) a

    UNION ALL
    -- a manual share of a posted charge cannot sit on a line that receives nothing (it could not enter any cost)
    SELECT * FROM (SELECT TOP (1) Seq = 16, ErrorNumber = 70013,
                          Message = N'The posted charge ' + t.ChargeName + N' has a manual share on line ' + CAST(cl.LineNumber AS NVARCHAR(10))
                                    + N' (' + i.ItemCode + N'), which receives nothing. Cancel that charge and enter it again on the received lines.'
                   FROM h
                   INNER JOIN logistics.ContainerCharges ch           ON ch.ContainerId = h.ContainerId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1
                   INNER JOIN logistics.ContainerChargeAllocations a ON a.ChargeId = ch.Id AND a.IsManual = 1 AND a.AmountBase > 0
                   INNER JOIN purchase.ChargeTypes t                  ON t.Id = ch.ChargeTypeId
                   INNER JOIN logistics.ContainerLines cl             ON cl.Id = a.ContainerLineId
                   INNER JOIN inventory.Items i                       ON i.Id = cl.ItemId
                   LEFT  JOIN l                                       ON l.ContainerLineId = cl.Id
                   WHERE h.SourceKind = N'Container' AND ISNULL(l.QuantityBase, cl.QuantityBase) = 0
                   ORDER BY cl.LineNumber) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 17, ErrorNumber = 63010,
                          Message = CASE WHEN po.Status = 3 THEN N'The purchase order ' + ISNULL(po.DocumentNumber, N'') + N' is cancelled.'
                                         ELSE N'Only an approved order can be received: the purchase order '
                                              + ISNULL(po.DocumentNumber, N'(draft)') + N' is not approved.' END
                   FROM (SELECT DISTINCT l.PurchaseOrderId FROM l WHERE l.PurchaseOrderId IS NOT NULL) x
                   INNER JOIN purchase.PurchaseDocuments po ON po.Id = x.PurchaseOrderId
                   WHERE po.Status NOT IN (2, 4)
                   ORDER BY po.Id) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 18, ErrorNumber = 63010,
                          Message = CASE WHEN d.Status = 3 THEN N'The purchase invoice ' + ISNULL(d.DocumentNumber, N'') + N' is cancelled: receive the goods from the order, or delete this goods receipt.'
                                         WHEN d.Status NOT IN (2, 4) THEN N'Post the invoice first: goods are received against a posted invoice, or from the order.'
                                         WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 THEN N'Posted before goods receipts: the stock of ' + ISNULL(d.DocumentNumber, N'') + N' entered when it was posted.'
                                         ELSE N'This invoice''s goods travel in containers: they are received with their containers.' END
                   FROM l
                   INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = l.InvoiceLineId
                   INNER JOIN purchase.PurchaseDocuments d      ON d.Id = il.DocumentId
                   WHERE d.Status NOT IN (2, 4) OR (d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1) OR il.ContainerLineId IS NOT NULL
                   ORDER BY l.LineNumber) a

    UNION ALL
    -- ORDER CAP, lines received outside containers only: their own container never counts against a container line
    SELECT * FROM (SELECT TOP (1) Seq = 19, ErrorNumber = 63011,
                          Message = N'Line ' + CAST(q.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(q.Rec AS NVARCHAR(20))
                                    + N' pcs received but only ' + CAST(p.MaxOutsideBase AS NVARCHAR(20))
                                    + N' remain to receive on the order line outside containers.'
                   FROM (SELECT l.PoLineId, l.PurchaseOrderId, Rec = SUM(l.QuantityBase), LineNumber = MIN(l.LineNumber)
                         FROM l WHERE l.PoLineId IS NOT NULL AND l.ContainerLineId IS NULL
                         GROUP BY l.PoLineId, l.PurchaseOrderId) q
                   CROSS APPLY purchase.fn_PoLine_Progress(q.PurchaseOrderId) p
                   INNER JOIN inventory.Items i ON i.Id = p.ItemId
                   WHERE p.PoLineId = q.PoLineId AND q.Rec > p.MaxOutsideBase
                   ORDER BY q.LineNumber) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 20, ErrorNumber = 63011,
                          Message = N'Line ' + CAST(q.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(q.Rec AS NVARCHAR(20))
                                    + N' pcs received but only '
                                    + CAST(CASE WHEN il.QuantityBase > il.ReceivedQuantityBase THEN il.QuantityBase - il.ReceivedQuantityBase ELSE 0 END AS NVARCHAR(20))
                                    + N' remain to receive on invoice ' + ISNULL(d.DocumentNumber, N'') + N'.'
                   FROM (SELECT l.InvoiceLineId, Rec = SUM(l.QuantityBase), LineNumber = MIN(l.LineNumber)
                         FROM l WHERE l.InvoiceLineId IS NOT NULL AND l.PoLineId IS NULL
                         GROUP BY l.InvoiceLineId) q
                   INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = q.InvoiceLineId
                   INNER JOIN purchase.PurchaseDocuments d      ON d.Id = il.DocumentId
                   INNER JOIN inventory.Items i                 ON i.Id = il.ItemId
                   WHERE q.Rec > il.QuantityBase - il.ReceivedQuantityBase
                   ORDER BY q.LineNumber) a

    UNION ALL
    -- WITHOUT AN ORDER: refused while the supplier has the item to receive on an order (or on an invoice without an order)
    SELECT * FROM (SELECT TOP (1) Seq = 21, ErrorNumber = 63011,
                          Message = s.PartyCode + N' has ' + ISNULL(po.DocumentNumber, N'an order') + N' with ' + CAST(p.OutstandingBase AS NVARCHAR(20))
                                    + N' pcs of ' + l.ItemCode + N' still to receive: receive them from the order.'
                   FROM h
                   INNER JOIN masterdata.Parties s          ON s.Id = h.SupplierId
                   INNER JOIN l                             ON l.PoLineId IS NULL AND l.InvoiceLineId IS NULL
                   INNER JOIN purchase.PurchaseDocuments po ON po.SupplierId = h.SupplierId AND po.Status IN (2, 4)
                   INNER JOIN inventory.DocumentTypes dt    ON dt.Id = po.DocumentTypeId AND dt.Code = N'PO'
                   CROSS APPLY purchase.fn_PoLine_Progress(po.Id) p
                   WHERE p.ItemId = l.ItemId AND p.OutstandingBase > 0
                   ORDER BY l.LineNumber, po.Id) a

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 22, ErrorNumber = 63011,
                          Message = s.PartyCode + N' has ' + ISNULL(d.DocumentNumber, N'an invoice') + N' with '
                                    + CAST(il.QuantityBase - il.ReceivedQuantityBase AS NVARCHAR(20))
                                    + N' pcs of ' + l.ItemCode + N' still to receive: receive them from the invoice.'
                   FROM h
                   INNER JOIN masterdata.Parties s              ON s.Id = h.SupplierId
                   INNER JOIN l                                 ON l.PoLineId IS NULL AND l.InvoiceLineId IS NULL
                   INNER JOIN purchase.PurchaseDocuments d      ON d.SupplierId = h.SupplierId AND d.Status IN (2, 4)
                                                               AND NOT (d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1)
                   INNER JOIN inventory.DocumentTypes dt        ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
                   INNER JOIN purchase.PurchaseDocumentLines il ON il.DocumentId = d.Id AND il.SourceLineId IS NULL AND il.ItemId = l.ItemId
                   WHERE il.QuantityBase > il.ReceivedQuantityBase
                   ORDER BY l.LineNumber, d.Id) a

    UNION ALL
    SELECT 23, 63010, N'The document type GRN is inactive: activate it in Configuration ' + NCHAR(8250) + N' Document Types.'
    WHERE NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Code = N'GRN' AND IsActive = 1)
) x;

GO

