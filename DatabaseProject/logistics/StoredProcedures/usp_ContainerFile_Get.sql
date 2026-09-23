CREATE   PROCEDURE logistics.usp_ContainerFile_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ContainerId, AttachmentTypeId, FileName, ContentType, SizeBytes, Content, Note, DocumentDate, CreatedAtUtc, CreatedBy
    FROM logistics.ContainerFiles WHERE Id = @Id;
END
GO

