CREATE TABLE [sales].[ReceiptAudit] (
    [Id]        BIGINT         IDENTITY (1, 1) NOT NULL,
    [ReceiptId] INT            NOT NULL,
    [Action]    NVARCHAR (20)  NOT NULL,
    [Details]   NVARCHAR (500) NULL,
    [UserId]    INT            NULL,
    [AtUtc]     DATETIME2 (3)  CONSTRAINT [DF_ReceiptAudit_AtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_ReceiptAudit] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_ReceiptAudit_Receipt] FOREIGN KEY ([ReceiptId]) REFERENCES [sales].[Receipts] ([Id]),
    CONSTRAINT [FK_ReceiptAudit_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_ReceiptAudit_Receipt]
    ON [sales].[ReceiptAudit]([ReceiptId] ASC, [AtUtc] DESC);


GO

