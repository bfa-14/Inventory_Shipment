/* ------------------------------------------------------------------ Attachments */

CREATE   PROCEDURE logistics.usp_ContainerFile_Add
    @ContainerId      INT,
    @AttachmentTypeId INT            = NULL,
    @FileName         NVARCHAR(255),
    @ContentType      NVARCHAR(100),
    @SizeBytes        INT,
    @Content          VARBINARY(MAX),
    @Note             NVARCHAR(300)  = NULL,
    @DocumentDate     DATE           = NULL,
    @UserId           INT            = NULL,
    @NewId            INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @ContainerId) THROW 69006, 'Container not found.', 1;
    IF @SizeBytes IS NULL OR @SizeBytes <= 0 THROW 69000, 'The file is empty.', 1;
    IF @AttachmentTypeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.AttachmentTypes WHERE Id = @AttachmentTypeId)
        THROW 69000, 'Attachment type not found.', 1;

    INSERT INTO logistics.ContainerFiles (ContainerId, AttachmentTypeId, FileName, ContentType, SizeBytes, Content, Note, DocumentDate, CreatedBy)
    VALUES (@ContainerId, @AttachmentTypeId, @FileName, @ContentType, @SizeBytes, @Content, NULLIF(LTRIM(RTRIM(@Note)), N''), @DocumentDate, @UserId);
    SET @NewId = SCOPE_IDENTITY();

    INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
    VALUES (@ContainerId, N'Updated', N'Attachment added: ' + @FileName, @UserId);
END
GO

