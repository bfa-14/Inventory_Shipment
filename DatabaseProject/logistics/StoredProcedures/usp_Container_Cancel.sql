CREATE   PROCEDURE logistics.usp_Container_Cancel
    @Id INT, @Reason NVARCHAR(300), @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 69000, 'A cancellation reason is required.', 1;

    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @Id);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status >= 6 THROW 69010, 'An offloaded, closed or cancelled container cannot be cancelled. Reverse the offload first.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;

    DECLARE @Msg NVARCHAR(400);
    IF EXISTS (SELECT 1 FROM logistics.ContainerLines cl
               INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
               INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
               WHERE cl.ContainerId = @Id AND d.Status <> 3)
    BEGIN
        SELECT TOP (1) @Msg = N'The container is invoiced by ' + ISNULL(d.DocumentNumber, N'a draft invoice') + N'. Cancel or delete its invoices first.'
        FROM logistics.ContainerLines cl
        INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
        INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
        WHERE cl.ContainerId = @Id AND d.Status <> 3
        ORDER BY d.Status DESC, d.DocumentNumber;
        THROW 69012, @Msg, 1;
    END
    IF EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE ContainerId = @Id AND Status IN (1, 2))
        THROW 70014, 'The container has charges. Delete the drafts and cancel the posted ones first.', 1;
    SELECT TOP (1) @Msg = N'The container is part of movement ' + m.MovementNo + N'. Remove it from that movement first.'
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
    WHERE mc.ContainerId = @Id AND m.Status IN (1, 2)
    ORDER BY m.MovementNo;
    IF @Msg IS NOT NULL THROW 70012, @Msg, 1;

    UPDATE logistics.Containers
    SET Status = 8, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
    INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);
END

GO

