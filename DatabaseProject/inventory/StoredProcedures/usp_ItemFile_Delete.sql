CREATE   PROCEDURE inventory.usp_ItemFile_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.ItemFiles WHERE Id = @Id)
        THROW 56006, 'File not found.', 1;
    DELETE FROM inventory.ItemFiles WHERE Id = @Id;
END

GO

