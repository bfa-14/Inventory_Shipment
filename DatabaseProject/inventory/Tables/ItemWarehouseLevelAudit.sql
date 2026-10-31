CREATE TABLE [inventory].[ItemWarehouseLevelAudit] (
    [Id]          BIGINT         IDENTITY (1, 1) NOT NULL,
    [ItemId]      INT            NOT NULL,
    [WarehouseId] INT            NOT NULL,
    [Action]      NVARCHAR (10)  NOT NULL,
    [OldMinBase]  INT            NULL,
    [OldMaxBase]  INT            NULL,
    [NewMinBase]  INT            NULL,
    [NewMaxBase]  INT            NULL,
    [Source]      NVARCHAR (20)  NOT NULL,
    [FileName]    NVARCHAR (260) NULL,
    [UserId]      INT            NULL,
    [AtUtc]       DATETIME2 (3)  CONSTRAINT [DF_ItemWarehouseLevelAudit_AtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_ItemWarehouseLevelAudit] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ItemWarehouseLevelAudit_Action] CHECK ([Action]=N'Removed' OR [Action]=N'Changed' OR [Action]=N'Added'),
    CONSTRAINT [CK_ItemWarehouseLevelAudit_Source] CHECK ([Source]=N'Import' OR [Source]=N'StockLevels' OR [Source]=N'ItemCard'),
    CONSTRAINT [FK_ItemWarehouseLevelAudit_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_ItemWarehouseLevelAudit_Level]
    ON [inventory].[ItemWarehouseLevelAudit]([ItemId] ASC, [WarehouseId] ASC, [AtUtc] DESC);


GO

