CREATE   PROCEDURE purchase.usp_GoodsReceipt_File_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ReceiptId INT, @Name NVARCHAR(255);
    SELECT @ReceiptId = GoodsReceiptId, @Name = FileName FROM purchase.GoodsReceiptFiles WHERE Id = @Id;
    IF @ReceiptId IS NULL THROW 63006, 'File not found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE FROM purchase.GoodsReceiptFiles WHERE Id = @Id;
        INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId) VALUES (@ReceiptId, N'FileDeleted', LEFT(@Name, 500), @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

