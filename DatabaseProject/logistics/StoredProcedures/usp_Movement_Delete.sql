CREATE   PROCEDURE logistics.usp_Movement_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Movements WHERE Id = @Id);
    IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
    IF @Status <> 1 THROW 70005, 'Only a planned movement can be deleted. Cancel the others.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ContainerCharges WHERE MovementId = @Id)
       OR EXISTS (SELECT 1 FROM logistics.ContainerAttachments WHERE MovementId = @Id)
        THROW 70014, 'Charges or attachments refer to this movement. Cancel it instead.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM logistics.MovementContainers WHERE MovementId = @Id;
        DELETE FROM logistics.Movements WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

