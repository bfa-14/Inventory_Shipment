
CREATE   PROCEDURE messaging.usp_Email_Retry
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM messaging.EmailOutbox WHERE Id = @Id) THROW 65006, 'Email not found.', 1;
    UPDATE messaging.EmailOutbox SET Status = 1, Attempts = 0, NextAttemptAtUtc = SYSUTCDATETIME() WHERE Id = @Id AND Status <> 2;
END

GO

