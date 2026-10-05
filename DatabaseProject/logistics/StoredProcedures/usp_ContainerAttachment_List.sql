CREATE   PROCEDURE logistics.usp_ContainerAttachment_List
    @ContainerId INT = NULL, @MovementId INT = NULL, @AttachmentTypeId INT = NULL, @Id INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.Id, a.ContainerId, c.ContainerRef, a.MovementId, m.MovementNo, a.ChargeId, a.FileId, f.FileName, f.ContentType, f.SizeBytes,
           a.AttachmentTypeId, t.Category, t.SubType,
           IsOther = CAST(CASE WHEN t.Id IS NULL OR (t.SubType = N'Other' AND t.Category IN (N'Other', N'General')) THEN 1 ELSE 0 END AS BIT),
           a.DocumentDate, a.Note, a.GroupId,
           SharedWith = (SELECT COUNT(*) FROM logistics.ContainerAttachments s WHERE s.FileId = a.FileId AND s.Id <> a.Id),
           a.CreatedAtUtc, a.CreatedBy, u.FullName AS CreatedByName
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Containers c ON c.Id = a.ContainerId
    INNER JOIN logistics.Files f ON f.Id = a.FileId
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = a.AttachmentTypeId
    LEFT JOIN logistics.Movements m ON m.Id = a.MovementId
    LEFT JOIN security.Users u ON u.Id = a.CreatedBy
    WHERE (@ContainerId IS NULL OR a.ContainerId = @ContainerId) AND (@MovementId IS NULL OR a.MovementId = @MovementId)
      AND (@AttachmentTypeId IS NULL OR a.AttachmentTypeId = @AttachmentTypeId) AND (@Id IS NULL OR a.Id = @Id)
      AND (@ContainerId IS NOT NULL OR @MovementId IS NOT NULL OR @Id IS NOT NULL)
    ORDER BY a.CreatedAtUtc DESC, a.Id DESC;
END

GO

