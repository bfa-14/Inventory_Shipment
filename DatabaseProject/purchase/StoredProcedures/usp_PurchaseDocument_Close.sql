CREATE   PROCEDURE purchase.usp_PurchaseDocument_Close
    @Id         INT,
    @Reason     NVARCHAR(300) = NULL,
    @RowVersion BINARY(8)     = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Status TINYINT, @TypeCode NVARCHAR(20);
    SELECT @Status = d.Status, @TypeCode = dt.Code FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @Id;
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PO' THROW 65010, 'Only purchase orders can be closed.', 1;
    IF @Status <> 2 THROW 65010, 'Only open (posted) purchase orders can be closed.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

    DECLARE @Ct NVARCHAR(400);
    SELECT TOP (1) @Ct = N'Container ' + c.ContainerRef + N' carries lines of this order that are not fully invoiced. Invoice them (or remove the lines) before closing the order.'
    FROM logistics.ContainerLines cl
    INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
    OUTER APPLY (SELECT Q = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND pd.Status IN (2, 4)) q
    WHERE cl.PurchaseOrderId = @Id AND c.Status NOT IN (6, 7, 8) AND ISNULL(q.Q, 0) < cl.QuantityBase
    ORDER BY c.ContainerRef;
    IF @Ct IS NOT NULL THROW 65021, @Ct, 1;

    UPDATE purchase.PurchaseDocuments
    SET Status = 4, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, CloseReason = ISNULL(NULLIF(LTRIM(RTRIM(@Reason)), N''), N'Closed manually'),
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
    INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Closed', ISNULL(@Reason, N'Closed manually'), @UserId);
END

GO

