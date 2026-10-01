CREATE   PROCEDURE messaging.usp_EmailSettings_Get
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.Id, e.SendingEnabled, e.SmtpHost, e.SmtpPort, e.SmtpSecurity, e.SmtpUserName, e.FromAddress, e.FromName,
           e.ReplyToAddress, e.PublicBaseUrl, e.LastTestAtUtc, e.LastTestOk, e.LastTestError, e.UpdatedAtUtc, e.UpdatedBy,
           e.RowVersion,
           HasPassword   = CAST(CASE WHEN e.SmtpPasswordProtected IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           IsSaved       = CAST(CASE WHEN e.UpdatedAtUtc IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           UpdatedByName = u.FullName
    FROM messaging.EmailSettings e
    LEFT JOIN security.Users u ON u.Id = e.UpdatedBy
    WHERE e.Id = 1;
END

GO

