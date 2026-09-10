CREATE TABLE [inventory].[StockDocumentAudit] (
    [Id]         BIGINT         IDENTITY (1, 1) NOT NULL,
    [DocumentId] INT            NOT NULL,
    [Action]     NVARCHAR (20)  NOT NULL,
    [Details]    NVARCHAR (500) NULL,
    [UserId]     INT            NULL,
    [AtUtc]      DATETIME2 (3)  CONSTRAINT [DF_StockDocumentAudit_AtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_StockDocumentAudit] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_StockDocumentAudit_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id])
);


GO
CREATE NONCLUSTERED INDEX [IX_StockDocumentAudit_Document]
    ON [inventory].[StockDocumentAudit]([DocumentId] ASC, [AtUtc] ASC);

