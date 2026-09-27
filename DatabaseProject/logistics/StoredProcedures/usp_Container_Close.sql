CREATE   PROCEDURE logistics.usp_Container_Close
    @Id INT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @Id);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status <> 6 THROW 69010, 'Only an offloaded container can be closed.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE ContainerId = @Id AND Status = 1)
        THROW 70010, 'The container still has draft charges. Post or delete them before closing it.', 1;

    UPDATE logistics.Containers
    SET Status = 7, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
    INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'Closed', N'Container closed', @UserId);
END

GO

