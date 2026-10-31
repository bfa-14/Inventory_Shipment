-- (DocumentId = the item); IsOther = still typed "Other". Never the item's picture.
CREATE   PROCEDURE inventory.usp_ItemFile_List
    @ItemId INT, @AttachmentTypeId INT = NULL, @FileId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.Id, f.ItemId AS DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.AttachmentTypeId, t.Category, t.SubType,
           IsOther = CAST(CASE WHEN t.SubType = N'Other' AND t.Category IN (N'Other', N'General') THEN 1 ELSE 0 END AS BIT),
           f.DocumentDate, f.Note, f.CreatedAtUtc, f.CreatedBy, u.FullName AS CreatedByName
    FROM inventory.ItemFiles f
    LEFT JOIN masterdata.AttachmentTypes t ON t.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.ItemId = @ItemId AND f.IsItemImage = 0
      AND (@AttachmentTypeId IS NULL OR f.AttachmentTypeId = @AttachmentTypeId) AND (@FileId IS NULL OR f.Id = @FileId)
    ORDER BY f.CreatedAtUtc DESC, f.Id DESC;
END

GO

