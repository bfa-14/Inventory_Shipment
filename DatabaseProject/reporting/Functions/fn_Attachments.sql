/* ================================================================== 4. reporting.fn_Attachments */

CREATE   FUNCTION reporting.fn_Attachments ()
RETURNS TABLE
AS
RETURN
(
    -- A container's documents: one row per container the file is filed under (one upload may serve several).
    SELECT Source = CAST(N'CNT' AS NVARCHAR(4)), a.Id, DocumentKind = CAST(N'CONTAINER' AS NVARCHAR(12)),
           OwnerId = a.ContainerId, Reference = CAST(c.ContainerRef AS NVARCHAR(60)), a.AttachmentTypeId,
           f.FileName, f.ContentType, f.SizeBytes, a.DocumentDate, UploadedAtUtc = a.CreatedAtUtc, UploadedBy = a.CreatedBy
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Files f      ON f.Id = a.FileId
    INNER JOIN logistics.Containers c ON c.Id = a.ContainerId

    UNION ALL
    SELECT N'PDOC', x.Id, dt.Code, x.DocumentId,
           ISNULL(d.DocumentNumber, dt.Code + N' draft #' + CAST(d.Id AS NVARCHAR(12))), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM purchase.PurchaseDocumentFiles x
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = x.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId

    UNION ALL
    SELECT N'GRN', x.Id, N'GRN', x.GoodsReceiptId,
           ISNULL(g.DocumentNumber, N'GRN draft #' + CAST(g.Id AS NVARCHAR(12))), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM purchase.GoodsReceiptFiles x
    INNER JOIN purchase.GoodsReceipts g ON g.Id = x.GoodsReceiptId

    UNION ALL
    SELECT N'PAY', x.Id, N'PAY', x.PaymentId,
           ISNULL(p.PaymentNumber, N'PAY draft #' + CAST(p.Id AS NVARCHAR(12))), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM purchase.PaymentFiles x
    INNER JOIN purchase.Payments p ON p.Id = x.PaymentId

    UNION ALL
    SELECT N'SDOC', x.Id, dt.Code, x.DocumentId,
           ISNULL(d.DocumentNumber, dt.Code + N' draft #' + CAST(d.Id AS NVARCHAR(12))), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM sales.SalesDocumentFiles x
    INNER JOIN sales.SalesDocuments d     ON d.Id = x.DocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId

    UNION ALL
    SELECT N'RCPT', x.Id, N'RCPT', x.ReceiptId,
           ISNULL(r.ReceiptNumber, N'RCPT draft #' + CAST(r.Id AS NVARCHAR(12))), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM sales.ReceiptFiles x
    INNER JOIN sales.Receipts r ON r.Id = x.ReceiptId

    UNION ALL
    SELECT N'STK', x.Id, dt.Code, x.DocumentId,
           ISNULL(d.DocumentNumber, dt.Code + N' draft #' + CAST(d.Id AS NVARCHAR(12))), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM inventory.StockDocumentFiles x
    INNER JOIN inventory.StockDocuments d ON d.Id = x.DocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId

    UNION ALL
    SELECT N'TRO', x.Id, dt.Code, x.TransferOrderId,
           ISNULL(t.DocumentNumber, dt.Code + N' draft #' + CAST(t.Id AS NVARCHAR(12))), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM inventory.TransferOrderFiles x
    INNER JOIN inventory.TransferOrders t ON t.Id = x.TransferOrderId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = t.DocumentTypeId

    UNION ALL
    -- The item's picture is not one of its documents.
    SELECT N'ITEM', x.Id, N'ITEM', x.ItemId, CAST(i.ItemCode AS NVARCHAR(60)), x.AttachmentTypeId,
           x.FileName, x.ContentType, x.SizeBytes, x.DocumentDate, x.CreatedAtUtc, x.CreatedBy
    FROM inventory.ItemFiles x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    WHERE x.IsItemImage = 0
);