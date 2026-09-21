CREATE   PROCEDURE inventory.usp_ShortageDocument_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM inventory.ShortageDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
    IF @Status <> 1 THROW 66005, 'Only draft shortage documents can be deleted.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE purchase.PurchaseDocuments SET SourceShortageId = NULL WHERE SourceShortageId = @Id;
        DELETE FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id;
        DELETE FROM inventory.ShortageDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM inventory.ShortageDocuments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

