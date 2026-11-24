/* ================================================================== 2. Back to draft */

CREATE   PROCEDURE inventory.usp_ShortageDocument_Unpost
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- The plan's row is held to the end, so a purchase order cannot be made from it meanwhile.
        DECLARE @Status TINYINT = (SELECT Status FROM inventory.ShortageDocuments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id);
        IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;

        DECLARE @Block NVARCHAR(400) = inventory.fn_ShortageDocument_UnpostBlock(@Id);
        IF @Block IS NOT NULL THROW 66010, @Block, 1;

        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.ShortageDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 66004, 'This document was modified by another user. Reload the page and try again.', 1;

        UPDATE inventory.ShortageDocuments
        SET Status = 1, PostedAtUtc = NULL, PostedBy = NULL, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Back to draft', N'No purchase order made from it: it can be changed, posted again or deleted', @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

