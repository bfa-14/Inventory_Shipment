
CREATE   PROCEDURE logistics.usp_Container_Confirm
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @Id);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status <> 1 THROW 69010, 'Only a draft container can be confirmed.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.ContainerLines WHERE ContainerId = @Id)
        THROW 69009, 'The container has no items. Load at least one invoice line before confirming.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE logistics.Containers
        SET ConfirmedAtUtc = SYSUTCDATETIME(), ConfirmedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        EXEC logistics.usp_Container_RefreshStatus @Id;
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@Id, N'Confirmed', N'Loading plan confirmed', @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

