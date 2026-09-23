CREATE TABLE [purchase].[PurchaseDocumentAudit] (
    [Id]         BIGINT         IDENTITY (1, 1) NOT NULL,
    [DocumentId] INT            NOT NULL,
    [Action]     NVARCHAR (20)  NOT NULL,
    [Details]    NVARCHAR (500) NULL,
    [UserId]     INT            NULL,
    [AtUtc]      DATETIME2 (3)  CONSTRAINT [DF_PurchaseDocumentAudit_AtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_PurchaseDocumentAudit] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_PurchaseDocumentAudit_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_PurchaseDocumentAudit_Document]
    ON [purchase].[PurchaseDocumentAudit]([DocumentId] ASC, [AtUtc] ASC);


GO

