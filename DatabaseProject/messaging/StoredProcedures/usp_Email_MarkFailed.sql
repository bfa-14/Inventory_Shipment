CREATE   PROCEDURE messaging.usp_Email_MarkFailed
    @Id          BIGINT,
    @Error       NVARCHAR(1000),
    @MaxAttempts INT = 5
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE messaging.EmailOutbox
    SET LastError = LEFT(@Error, 1000),
        Status = CASE WHEN Attempts >= @MaxAttempts THEN 3 ELSE 1 END,
        NextAttemptAtUtc = DATEADD(MINUTE, 5 * Attempts, SYSUTCDATETIME())
    WHERE Id = @Id;
END

GO

