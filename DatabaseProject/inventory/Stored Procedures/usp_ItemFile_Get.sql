CREATE   PROCEDURE inventory.usp_ItemFile_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ItemId, FileName, ContentType, SizeBytes, IsItemImage, Content, CreatedAtUtc
    FROM inventory.ItemFiles WHERE Id = @Id;
END