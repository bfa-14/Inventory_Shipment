CREATE   PROCEDURE inventory.usp_TransferOrder_File_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @OrderId INT, @Name NVARCHAR(255);
    SELECT @OrderId = TransferOrderId, @Name = FileName FROM inventory.TransferOrderFiles WHERE Id = @Id;
    IF @OrderId IS NULL THROW 62006, 'File not found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM inventory.TransferOrderFiles WHERE Id = @Id;
        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId) VALUES (@OrderId, N'FileDeleted', LEFT(@Name, 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

