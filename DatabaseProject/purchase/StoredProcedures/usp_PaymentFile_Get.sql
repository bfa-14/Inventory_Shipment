CREATE   PROCEDURE purchase.usp_PaymentFile_Get
    @PaymentId INT, @FileId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, PaymentId, FileName, ContentType, SizeBytes, Content
    FROM purchase.PaymentFiles WHERE Id = @FileId AND PaymentId = @PaymentId;
END

GO

