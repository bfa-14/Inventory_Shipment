CREATE TABLE [sales].[SalesDocumentAudit] (
    [Id]         BIGINT         IDENTITY (1, 1) NOT NULL,
    [DocumentId] INT            NOT NULL,
    [Action]     NVARCHAR (20)  NOT NULL,
    [Details]    NVARCHAR (500) NULL,
    [UserId]     INT            NULL,
    [AtUtc]      DATETIME2 (3)  CONSTRAINT [DF_SalesDocumentAudit_AtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_SalesDocumentAudit] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_SalesDocumentAudit_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id])
);


GO
CREATE NONCLUSTERED INDEX [IX_SalesDocumentAudit_Document]
    ON [sales].[SalesDocumentAudit]([DocumentId] ASC, [AtUtc] ASC);

