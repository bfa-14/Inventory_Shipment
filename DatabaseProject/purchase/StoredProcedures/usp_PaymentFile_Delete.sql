CREATE   PROCEDURE purchase.usp_PaymentFile_Delete
    @PaymentId INT, @FileId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM purchase.Payments WHERE Id = @PaymentId);
    IF @Status IS NULL THROW 73006, 'Payment not found.', 1;
    -- (49) a draft or a posted payment; a reversed one is closed. Every removal is in the payment's audit.
    IF @Status = 3 THROW 73005, 'A reversed payment is closed; its files can no longer be removed.', 1;

    DECLARE @Name NVARCHAR(255) = (SELECT FileName FROM purchase.PaymentFiles WHERE Id = @FileId AND PaymentId = @PaymentId);
    IF @Name IS NULL THROW 73006, 'File not found.', 1;

    DELETE FROM purchase.PaymentFiles WHERE Id = @FileId AND PaymentId = @PaymentId;
    INSERT INTO purchase.PaymentAudit (PaymentId, Action, Details, UserId) VALUES (@PaymentId, N'FileDeleted', @Name, @UserId);
END

GO

