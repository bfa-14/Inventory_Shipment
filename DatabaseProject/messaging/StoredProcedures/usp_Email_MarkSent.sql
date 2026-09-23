
CREATE   PROCEDURE messaging.usp_Email_MarkSent
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE messaging.EmailOutbox SET Status = 2, SentAtUtc = SYSUTCDATETIME(), LastError = NULL WHERE Id = @Id;
END

GO

