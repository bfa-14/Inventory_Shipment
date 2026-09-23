
CREATE   PROCEDURE messaging.usp_Email_Enqueue
    @ToAddresses           NVARCHAR(1000),
    @CcAddresses           NVARCHAR(1000) = NULL,
    @Subject               NVARCHAR(300),
    @BodyHtml              NVARCHAR(MAX),
    @AttachmentName        NVARCHAR(255)  = NULL,
    @AttachmentContentType NVARCHAR(100)  = NULL,
    @AttachmentContent     VARBINARY(MAX) = NULL,
    @Category              NVARCHAR(40),
    @RelatedDocumentId     INT            = NULL,
    @UserId                INT            = NULL,
    @NewId                 BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @ToAddresses = NULLIF(LTRIM(RTRIM(@ToAddresses)), N'');
    SET @CcAddresses = NULLIF(LTRIM(RTRIM(@CcAddresses)), N'');
    IF @ToAddresses IS NULL THROW 65000, 'An email needs at least one recipient.', 1;
    IF NULLIF(LTRIM(RTRIM(@Subject)), N'') IS NULL THROW 65000, 'An email needs a subject.', 1;

    INSERT INTO messaging.EmailOutbox (ToAddresses, CcAddresses, Subject, BodyHtml, AttachmentName, AttachmentContentType,
                                       AttachmentContent, Category, RelatedDocumentId, CreatedBy)
    VALUES (@ToAddresses, @CcAddresses, @Subject, @BodyHtml, @AttachmentName, @AttachmentContentType,
            @AttachmentContent, @Category, @RelatedDocumentId, @UserId);
    SET @NewId = SCOPE_IDENTITY();
END

GO

