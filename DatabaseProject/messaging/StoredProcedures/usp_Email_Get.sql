
CREATE   PROCEDURE messaging.usp_Email_Get
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ToAddresses, CcAddresses, Subject, BodyHtml, AttachmentName, AttachmentContentType, AttachmentContent,
           Category, RelatedDocumentId, Status, Attempts, NextAttemptAtUtc, LastError, CreatedAtUtc, SentAtUtc
    FROM messaging.EmailOutbox WHERE Id = @Id;
END
GO

