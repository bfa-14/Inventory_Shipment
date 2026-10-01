CREATE   PROCEDURE messaging.usp_EmailSettings_GetForSending
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.Id, e.SendingEnabled, e.SmtpHost, e.SmtpPort, e.SmtpSecurity, e.SmtpUserName, e.SmtpPasswordProtected,
           e.FromAddress, e.FromName, e.ReplyToAddress, e.PublicBaseUrl, e.UpdatedAtUtc, e.RowVersion
    FROM messaging.EmailSettings e
    WHERE e.Id = 1;
END

GO

