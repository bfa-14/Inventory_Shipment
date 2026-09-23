/* ------------------------------------------------------------------ 4d. Post / Delete / Create PO */

CREATE   PROCEDURE inventory.usp_ShortageDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM inventory.ShortageDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 66006, 'Shortage document not found.', 1;
    IF @Status <> 1 THROW 66010, 'Only draft shortage documents can be posted.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.ShortageDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 66004, 'This document was modified by another user. Reload the page and try again.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.ShortageDocumentLines WHERE DocumentId = @Id)
        THROW 66009, 'The shortage document has no lines. Load items before posting.', 1;

    UPDATE inventory.ShortageDocuments
    SET Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
    INSERT INTO inventory.ShortageDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Posted', N'Snapshot locked', @UserId);
END

GO

