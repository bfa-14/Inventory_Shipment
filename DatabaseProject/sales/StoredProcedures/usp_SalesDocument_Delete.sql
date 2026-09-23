CREATE   PROCEDURE sales.usp_SalesDocument_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM sales.SalesDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 64006, 'Document not found.', 1;
    IF @Status <> 1 THROW 64005, 'Only draft documents can be deleted. Posted documents must be cancelled.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE sales.InvoiceImportLogs SET InvoiceId = NULL WHERE InvoiceId = @Id;   -- keep the import history
        DELETE FROM sales.SalesDocumentFiles WHERE DocumentId = @Id;
        DELETE FROM sales.SalesDocumentLines WHERE DocumentId = @Id;
        DELETE FROM sales.SalesDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM sales.SalesDocuments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

