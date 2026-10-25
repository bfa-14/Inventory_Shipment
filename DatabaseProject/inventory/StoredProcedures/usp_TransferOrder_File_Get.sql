CREATE   PROCEDURE inventory.usp_TransferOrder_File_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, TransferOrderId AS DocumentId, FileName, ContentType, SizeBytes, Content, CreatedAtUtc
    FROM inventory.TransferOrderFiles WHERE Id = @Id;
END

GO

