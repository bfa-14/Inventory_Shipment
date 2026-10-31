CREATE TABLE [purchase].[GoodsReceiptAudit] (
    [Id]             BIGINT         IDENTITY (1, 1) NOT NULL,
    [GoodsReceiptId] INT            NOT NULL,
    [Action]         NVARCHAR (20)  NOT NULL,
    [Details]        NVARCHAR (500) NULL,
    [UserId]         INT            NULL,
    [AtUtc]          DATETIME2 (3)  CONSTRAINT [DF_GoodsReceiptAudit_AtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_GoodsReceiptAudit] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_GoodsReceiptAudit_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_GoodsReceiptAudit_Receipt]
    ON [purchase].[GoodsReceiptAudit]([GoodsReceiptId] ASC, [AtUtc] ASC);


GO

