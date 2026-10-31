-- Re-created (65) from the body of script 27 the way Close is above: one transaction, the container read under lock
-- before the checks, and a guarded write (Status = 7) - the status it checks is the status it changes.
CREATE   PROCEDURE logistics.usp_Container_Reopen
    @Id INT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT;
        SELECT @Status = Status FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 69006, 'Container not found.', 1;
        IF @Status <> 7 THROW 69010, 'Only a closed container can be reopened.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM logistics.Containers c
                   INNER JOIN logistics.Containers o ON o.ContainerNo = c.ContainerNo AND o.Id <> c.Id AND o.Status < 7
                   WHERE c.Id = @Id AND c.ContainerNo IS NOT NULL)
            THROW 69013, 'Another open container already uses this container number. Change that one first.', 1;

        UPDATE logistics.Containers
        SET Status = 6, ClosedAtUtc = NULL, ClosedBy = NULL, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id AND Status = 7;
        IF @@ROWCOUNT = 0 THROW 69010, 'Only a closed container can be reopened.', 1;
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'Updated', N'Container reopened', @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

