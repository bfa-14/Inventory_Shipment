CREATE TABLE [inventory].[CostAdjustments] (
    [Id]             BIGINT          IDENTITY (1, 1) NOT NULL,
    [AdjustmentDate] DATETIME2 (3)   NOT NULL,
    [ItemId]         INT             NOT NULL,
    [WarehouseId]    INT             NOT NULL,
    [BranchId]       INT             NOT NULL,
    [Kind]           NVARCHAR (10)   NOT NULL,
    [AmountBase]     DECIMAL (18, 2) NOT NULL,
    [SourceKind]     NVARCHAR (10)   NOT NULL,
    [SourceId]       INT             NOT NULL,
    [SourceNumber]   NVARCHAR (30)   NOT NULL,
    [PurchaseLineId] INT             NULL,
    [CreatedAtUtc]   DATETIME2 (3)   NOT NULL,
    [CreatedBy]      INT             NULL
);
GO

ALTER TABLE [inventory].[CostAdjustments]
    ADD CONSTRAINT [PK_CostAdjustments] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

CREATE NONCLUSTERED INDEX [IX_CostAdjustments_Source]
    ON [inventory].[CostAdjustments]([SourceKind] ASC, [SourceId] ASC);
GO

CREATE NONCLUSTERED INDEX [IX_CostAdjustments_ItemDate]
    ON [inventory].[CostAdjustments]([ItemId] ASC, [AdjustmentDate] ASC);
GO

ALTER TABLE [inventory].[CostAdjustments]
    ADD CONSTRAINT [FK_CostAdjustments_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]);
GO

ALTER TABLE [inventory].[CostAdjustments]
    ADD CONSTRAINT [FK_CostAdjustments_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]);
GO

ALTER TABLE [inventory].[CostAdjustments]
    ADD CONSTRAINT [FK_CostAdjustments_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]);
GO

ALTER TABLE [inventory].[CostAdjustments]
    ADD CONSTRAINT [DF_CostAdjustments_CreatedAtUtc] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];
GO

ALTER TABLE [inventory].[CostAdjustments]
    ADD CONSTRAINT [CK_CostAdjustments_Kind] CHECK ([Kind]=N'COGS' OR [Kind]=N'Inventory');
GO

