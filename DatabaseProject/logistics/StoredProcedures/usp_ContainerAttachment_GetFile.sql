CREATE   PROCEDURE logistics.usp_ContainerAttachment_GetFile
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.Id, a.ContainerId, a.MovementId, a.ChargeId, f.FileName, f.ContentType, f.SizeBytes, f.Content
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Files f ON f.Id = a.FileId
    WHERE a.Id = @Id;
END

GO

