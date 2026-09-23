CREATE   PROCEDURE inventory.usp_StockDocument_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM inventory.StockDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 62006, 'Document not found.', 1;
    IF @Status <> 1 THROW 62005, 'Only draft documents can be deleted. Posted documents must be cancelled.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM inventory.StockDocumentFiles WHERE DocumentId = @Id;
        DELETE FROM inventory.StockDocumentLines WHERE DocumentId = @Id;
        DELETE FROM inventory.StockDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM inventory.StockDocuments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

