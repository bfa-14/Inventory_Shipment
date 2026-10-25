CREATE TABLE [inventory].[TransferOrderAudit] (
    [Id]              BIGINT         IDENTITY (1, 1) NOT NULL,
    [TransferOrderId] INT            NOT NULL,
    [PostingId]       INT            NULL,
    [Action]          NVARCHAR (30)  NOT NULL,
    [Details]         NVARCHAR (500) NULL,
    [UserId]          INT            NULL,
    [AtUtc]           DATETIME2 (3)  CONSTRAINT [DF_TransferOrderAudit_AtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_TransferOrderAudit] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_TransferOrderAudit_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_TransferOrderAudit_Order]
    ON [inventory].[TransferOrderAudit]([TransferOrderId] ASC, [AtUtc] ASC);


GO

