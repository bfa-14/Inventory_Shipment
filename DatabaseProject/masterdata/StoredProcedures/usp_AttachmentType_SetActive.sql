CREATE   PROCEDURE masterdata.usp_AttachmentType_SetActive
    @Id INT, @IsActive BIT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id) THROW 69006, 'Attachment type not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This attachment type was modified by another user. Reload the page and try again.', 1;
    UPDATE masterdata.AttachmentTypes SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END
GO

