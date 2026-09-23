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
    [Status]                TINYINT         NOT NULL,
    [Attempts]              INT             NOT NULL,
    [NextAttemptAtUtc]      DATETIME2 (3)   NOT NULL,
    [LastError]             NVARCHAR (1000) NULL,
    [CreatedAtUtc]          DATETIME2 (3)   NOT NULL,
    [CreatedBy]             INT             NULL,
    [SentAtUtc]             DATETIME2 (3)   NULL
);
GO

ALTER TABLE [messaging].[EmailOutbox]
    ADD CONSTRAINT [DF_EmailOutbox_Status] DEFAULT ((1)) FOR [Status];
GO

ALTER TABLE [messaging].[EmailOutbox]
    ADD CONSTRAINT [DF_EmailOutbox_Next] DEFAULT (sysutcdatetime()) FOR [NextAttemptAtUtc];
GO

ALTER TABLE [messaging].[EmailOutbox]
    ADD CONSTRAINT [DF_EmailOutbox_Attempts] DEFAULT ((0)) FOR [Attempts];
GO

ALTER TABLE [messaging].[EmailOutbox]
    ADD CONSTRAINT [DF_EmailOutbox_CreatedAtUtc] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];
GO

ALTER TABLE [messaging].[EmailOutbox]
    ADD CONSTRAINT [PK_EmailOutbox] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

CREATE NONCLUSTERED INDEX [IX_EmailOutbox_Document]
    ON [messaging].[EmailOutbox]([RelatedDocumentId] ASC);
GO

CREATE NONCLUSTERED INDEX [IX_EmailOutbox_Due]
    ON [messaging].[EmailOutbox]([Status] ASC, [NextAttemptAtUtc] ASC);
GO

ALTER TABLE [messaging].[EmailOutbox]
    ADD CONSTRAINT [CK_EmailOutbox_Status] CHECK ([Status]=(3) OR [Status]=(2) OR [Status]=(1));
GO

ALTER TABLE [messaging].[EmailOutbox]
    ADD CONSTRAINT [FK_EmailOutbox_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]);
GO

