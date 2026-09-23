CREATE TABLE [inventory].[ShortageDocumentAudit] (
    [Id]         BIGINT         IDENTITY (1, 1) NOT NULL,
    [DocumentId] INT            NOT NULL,
    [Action]     NVARCHAR (20)  NOT NULL,
    [Details]    NVARCHAR (500) NULL,
    [UserId]     INT            NULL,
    [AtUtc]      DATETIME2 (3)  CONSTRAINT [DF_ShortageDocumentAudit_AtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_ShortageDocumentAudit] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_ShortageDocumentAudit_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_ShortageDocumentAudit_Document]
    ON [inventory].[ShortageDocumentAudit]([DocumentId] ASC, [AtUtc] ASC);


GO

