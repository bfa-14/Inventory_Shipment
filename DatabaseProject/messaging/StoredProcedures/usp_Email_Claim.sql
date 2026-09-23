
-- Takes the next due emails for the background sender (safe with several API instances: READPAST + lease).
CREATE   PROCEDURE messaging.usp_Email_Claim
    @BatchSize    INT = 10,
    @LeaseMinutes INT = 5
AS
BEGIN
    SET NOCOUNT ON;
    IF @BatchSize IS NULL OR @BatchSize < 1 SET @BatchSize = 10;
    ;WITH due AS
    (
        SELECT TOP (@BatchSize) Id, Attempts, NextAttemptAtUtc
        FROM messaging.EmailOutbox WITH (UPDLOCK, READPAST, ROWLOCK)
        WHERE Status = 1 AND NextAttemptAtUtc <= SYSUTCDATETIME()
        ORDER BY Id
    )
    UPDATE due
    SET Attempts = Attempts + 1, NextAttemptAtUtc = DATEADD(MINUTE, @LeaseMinutes, SYSUTCDATETIME())
    OUTPUT inserted.Id;          -- the worker then reads each claimed email with usp_Email_Get
END
GO

