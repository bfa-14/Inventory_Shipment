CREATE   PROCEDURE logistics.usp_Container_Cancel
    @Id INT, @Reason NVARCHAR(300), @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 69000, 'A cancellation reason is required.', 1;

    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @Id);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status >= 6 THROW 69010, 'An offloaded or closed container cannot be cancelled. Reverse the offload first.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;

    UPDATE logistics.Containers
    SET Status = 8, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
    INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);
END
GO

