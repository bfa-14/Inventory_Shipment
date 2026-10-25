CREATE TABLE [purchase].[GoodsReceiptCostChanges] (
    [Id]                 INT             IDENTITY (1, 1) NOT NULL,
    [GoodsReceiptLineId] INT             NOT NULL,
    [ChangedAtUtc]       DATETIME2 (3)   CONSTRAINT [DF_GoodsReceiptCostChanges_At] DEFAULT (sysutcdatetime()) NOT NULL,
    [CauseKind]          NVARCHAR (12)   NOT NULL,
    [CauseId]            INT             NULL,
    [CauseNumber]        NVARCHAR (30)   NULL,
    [ReceivedBase]       INT             NOT NULL,
    [InStockBase]        DECIMAL (18, 6) CONSTRAINT [DF_GoodsReceiptCostChanges_InStock] DEFAULT ((0)) NOT NULL,
    [FobBefore]          DECIMAL (18, 6) NULL,
    [FobAfter]           DECIMAL (18, 6) NULL,
    [UnitCostBefore]     DECIMAL (18, 6) NULL,
    [UnitCostAfter]      DECIMAL (18, 6) NULL,
    [AmountBase]         DECIMAL (18, 2) CONSTRAINT [DF_GoodsReceiptCostChanges_Amount] DEFAULT ((0)) NOT NULL,
    [InventoryBase]      DECIMAL (18, 2) CONSTRAINT [DF_GoodsReceiptCostChanges_Inventory] DEFAULT ((0)) NOT NULL,
    [CogsBase]           DECIMAL (18, 2) CONSTRAINT [DF_GoodsReceiptCostChanges_Cogs] DEFAULT ((0)) NOT NULL,
    [CreatedBy]          INT             NULL,
    CONSTRAINT [PK_GoodsReceiptCostChanges] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_GoodsReceiptCostChanges_Cause] CHECK ([CauseKind]=N'NEGSTOCK' OR [CauseKind]=N'GRNCANCEL' OR [CauseKind]=N'GRNPOST' OR [CauseKind]=N'LCACANCEL' OR [CauseKind]=N'LCA' OR [CauseKind]=N'PINVCANCEL' OR [CauseKind]=N'PINV'),
    CONSTRAINT [CK_GoodsReceiptCostChanges_Split] CHECK ([AmountBase]=([InventoryBase]+[CogsBase])),
    CONSTRAINT [FK_GoodsReceiptCostChanges_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_GoodsReceiptCostChanges_Line] FOREIGN KEY ([GoodsReceiptLineId]) REFERENCES [purchase].[GoodsReceiptLines] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_GoodsReceiptCostChanges_Line]
    ON [purchase].[GoodsReceiptCostChanges]([GoodsReceiptLineId] ASC, [ChangedAtUtc] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_GoodsReceiptCostChanges_Cause]
    ON [purchase].[GoodsReceiptCostChanges]([CauseKind] ASC, [CauseId] ASC);


GO

