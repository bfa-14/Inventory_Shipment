CREATE TABLE [messaging].[EmailOutbox] (
    [Id]                    BIGINT          IDENTITY (1, 1) NOT NULL,
    [ToAddresses]           NVARCHAR (1000) NOT NULL,
    [CcAddresses]           NVARCHAR (1000) NULL,
    [Subject]               NVARCHAR (300)  NOT NULL,
    [BodyHtml]              NVARCHAR (MAX)  NOT NULL,
    [AttachmentName]        NVARCHAR (255)  NULL,
    [AttachmentContentType] NVARCHAR (100)  NULL,
    [AttachmentContent]     VARBINARY (MAX) NULL,
    [Category]              NVARCHAR (40)   NOT NULL,
    [RelatedDocumentId]     INT             NULL,
    [Status]                TINYINT         CONSTRAINT [DF_EmailOutbox_Status] DEFAULT ((1)) NOT NULL,
    [Attempts]              INT             CONSTRAINT [DF_EmailOutbox_Attempts] DEFAULT ((0)) NOT NULL,
    [NextAttemptAtUtc]      DATETIME2 (3)   CONSTRAINT [DF_EmailOutbox_Next] DEFAULT (sysutcdatetime()) NOT NULL,
    [LastError]             NVARCHAR (1000) NULL,
    [CreatedAtUtc]          DATETIME2 (3)   CONSTRAINT [DF_EmailOutbox_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]             INT             NULL,
    [SentAtUtc]             DATETIME2 (3)   NULL,
    CONSTRAINT [PK_EmailOutbox] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_EmailOutbox_Status] CHECK ([Status]=(3) OR [Status]=(2) OR [Status]=(1)),
    CONSTRAINT [FK_EmailOutbox_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_EmailOutbox_Due]
    ON [messaging].[EmailOutbox]([Status] ASC, [NextAttemptAtUtc] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_EmailOutbox_Document]
    ON [messaging].[EmailOutbox]([RelatedDocumentId] ASC);


GO

