-- Returns what usp_EmailSettings_Get returns.
CREATE   PROCEDURE messaging.usp_EmailSettings_Save
    @SendingEnabled        BIT,
    @SmtpHost              NVARCHAR(200) = NULL,
    @SmtpPort              INT,
    @SmtpSecurity          TINYINT,
    @SmtpUserName          NVARCHAR(256) = NULL,
    @PasswordAction        TINYINT       = 0,       -- 0 keep, 1 replace, 2 remove
    @SmtpPasswordProtected NVARCHAR(MAX) = NULL,
    @FromAddress           NVARCHAR(256) = NULL,
    @FromName              NVARCHAR(200) = NULL,
    @ReplyToAddress        NVARCHAR(256) = NULL,
    @PublicBaseUrl         NVARCHAR(300) = NULL,
    @RowVersion            BINARY(8)     = NULL,
    @UserId                INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT @SendingEnabled = ISNULL(@SendingEnabled, 0),
           @PasswordAction = ISNULL(@PasswordAction, 0),
           @SmtpHost = NULLIF(LTRIM(RTRIM(@SmtpHost)), N''),
           @SmtpUserName = NULLIF(LTRIM(RTRIM(@SmtpUserName)), N''),
           @SmtpPasswordProtected = NULLIF(LTRIM(RTRIM(@SmtpPasswordProtected)), N''),
           @FromAddress = NULLIF(LTRIM(RTRIM(@FromAddress)), N''),
           @FromName = NULLIF(LTRIM(RTRIM(@FromName)), N''),
           @ReplyToAddress = NULLIF(LTRIM(RTRIM(@ReplyToAddress)), N''),
           @PublicBaseUrl = NULLIF(LTRIM(RTRIM(@PublicBaseUrl)), N'');
    WHILE RIGHT(@PublicBaseUrl, 1) = N'/'
        SET @PublicBaseUrl = LEFT(@PublicBaseUrl, DATALENGTH(@PublicBaseUrl) / 2 - 1);
    SET @PublicBaseUrl = NULLIF(@PublicBaseUrl, N'');

    IF @SendingEnabled = 1 AND (@SmtpHost IS NULL OR @FromAddress IS NULL)
        THROW 65025, 'Enter the mail server and the sender address before switching sending on.', 1;
    IF @SmtpPort IS NULL OR @SmtpPort NOT BETWEEN 1 AND 65535
        THROW 65025, 'The port must be between 1 and 65535.', 1;
    IF @SmtpSecurity IS NULL OR @SmtpSecurity NOT IN (0, 1, 2)
        THROW 65025, 'Unknown security option.', 1;
    IF @FromAddress IS NOT NULL AND (@FromAddress NOT LIKE N'%_@_%._%' OR CHARINDEX(N' ', @FromAddress) > 0)
        THROW 65025, 'The sender address is not a valid email address.', 1;
    IF @ReplyToAddress IS NOT NULL AND (@ReplyToAddress NOT LIKE N'%_@_%._%' OR CHARINDEX(N' ', @ReplyToAddress) > 0)
        THROW 65025, 'The reply-to address is not a valid email address.', 1;
    IF @PublicBaseUrl IS NOT NULL AND @PublicBaseUrl NOT LIKE N'http://_%' AND @PublicBaseUrl NOT LIKE N'https://_%'
        THROW 65025, 'The address of the application must start with http:// or https://.', 1;
    IF @PasswordAction NOT IN (0, 1, 2)
        THROW 65025, 'Unknown password action.', 1;
    IF @PasswordAction = 1 AND @SmtpPasswordProtected IS NULL
        THROW 65025, 'Type the new password.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS (SELECT 1 FROM messaging.EmailSettings WITH (UPDLOCK, HOLDLOCK) WHERE Id = 1)
            INSERT INTO messaging.EmailSettings (Id) VALUES (1);
        ELSE IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM messaging.EmailSettings WHERE Id = 1 AND RowVersion = @RowVersion)
            THROW 65004, 'Someone else changed the email settings. Reload the page and try again.', 1;

        UPDATE messaging.EmailSettings
        SET SendingEnabled = @SendingEnabled, SmtpHost = @SmtpHost, SmtpPort = @SmtpPort, SmtpSecurity = @SmtpSecurity,
            SmtpUserName = @SmtpUserName,
            SmtpPasswordProtected = CASE @PasswordAction WHEN 1 THEN @SmtpPasswordProtected WHEN 2 THEN NULL
                                                         ELSE SmtpPasswordProtected END,
            FromAddress = @FromAddress, FromName = @FromName, ReplyToAddress = @ReplyToAddress, PublicBaseUrl = @PublicBaseUrl,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC messaging.usp_EmailSettings_Get;
END

GO

