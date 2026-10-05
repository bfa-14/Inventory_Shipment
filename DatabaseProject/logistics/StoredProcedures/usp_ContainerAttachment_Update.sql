CREATE   PROCEDURE logistics.usp_ContainerAttachment_Update
    @Id INT, @AttachmentTypeId INT = NULL, @DocumentDate DATE = NULL, @Note NVARCHAR(500) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ContainerId INT, @Name NVARCHAR(255);
    SELECT @ContainerId = a.ContainerId, @Name = f.FileName
    FROM logistics.ContainerAttachments a INNER JOIN logistics.Files f ON f.Id = a.FileId
    WHERE a.Id = @Id;
    IF @ContainerId IS NULL THROW 70006, 'Attachment not found.', 1;
    EXEC masterdata.usp_AttachmentType_CheckForKind @AttachmentTypeId, N'CONTAINER', 70017;

    UPDATE logistics.ContainerAttachments
    SET AttachmentTypeId = @AttachmentTypeId, DocumentDate = @DocumentDate, Note = NULLIF(LTRIM(RTRIM(@Note)), N'')
    WHERE Id = @Id;
    INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
    VALUES (@ContainerId, N'Updated', LEFT(N'Attachment changed: ' + @Name, 500), @UserId);
    EXEC logistics.usp_ContainerAttachment_List @Id = @Id;
END

GO

