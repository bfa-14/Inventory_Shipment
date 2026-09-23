CREATE   PROCEDURE logistics.usp_Container_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @Id);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status <> 1 THROW 69005, 'Only a draft container can be deleted. Cancel the others.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM logistics.ContainerLines WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerInvoices WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerEvents WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerFiles WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerAudit WHERE ContainerId = @Id;
        DELETE FROM logistics.Containers WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

