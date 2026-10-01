CREATE TABLE [messaging].[EmailSettings] (
    [Id]                    TINYINT         NOT NULL,
    [SendingEnabled]        BIT             CONSTRAINT [DF_EmailSettings_SendingEnabled] DEFAULT ((0)) NOT NULL,
    [SmtpHost]              NVARCHAR (200)  NULL,
    [SmtpPort]              INT             CONSTRAINT [DF_EmailSettings_SmtpPort] DEFAULT ((587)) NOT NULL,
    [SmtpSecurity]          TINYINT         CONSTRAINT [DF_EmailSettings_SmtpSecurity] DEFAULT ((1)) NOT NULL,
    [SmtpUserName]          NVARCHAR (256)  NULL,
    [SmtpPasswordProtected] NVARCHAR (MAX)  NULL,
    [FromAddress]           NVARCHAR (256)  NULL,
    [FromName]              NVARCHAR (200)  NULL,
    [ReplyToAddress]        NVARCHAR (256)  NULL,
    [PublicBaseUrl]         NVARCHAR (300)  NULL,
    [LastTestAtUtc]         DATETIME2 (0)   NULL,
    [LastTestOk]            BIT             NULL,
    [LastTestError]         NVARCHAR (1000) NULL,
    [UpdatedAtUtc]          DATETIME2 (0)   NULL,
    [UpdatedBy]             INT             NULL,
    [RowVersion]            ROWVERSION      NOT NULL,
    CONSTRAINT [PK_EmailSettings] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_EmailSettings_Id] CHECK ([Id]=(1)),
    CONSTRAINT [CK_EmailSettings_Port] CHECK ([SmtpPort]>=(1) AND [SmtpPort]<=(65535)),
    CONSTRAINT [CK_EmailSettings_Security] CHECK ([SmtpSecurity]=(2) OR [SmtpSecurity]=(1) OR [SmtpSecurity]=(0)),
    CONSTRAINT [FK_EmailSettings_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id])
);


GO

