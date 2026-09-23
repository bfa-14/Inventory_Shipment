CREATE TABLE [purchase].[LandedCostAdjustmentLines] (
    [Id]                   INT             IDENTITY (1, 1) NOT NULL,
    [AdjustmentId]         INT             NOT NULL,
    [PurchaseLineId]       INT             NOT NULL,
    [ItemId]               INT             NOT NULL,
    [WarehouseId]          INT             NOT NULL,
    [ReceivedBase]         INT             NOT NULL,
    [NetReceivedBase]      INT             NOT NULL,
    [RemainingBase]        INT             NOT NULL,
    [AllocatedBase]        DECIMAL (18, 2) NOT NULL,
    [ExtraPerBaseUnit]     DECIMAL (18, 6) NOT NULL,
    [InventoryPortionBase] DECIMAL (18, 2) NOT NULL,
    [CogsPortionBase]      DECIMAL (18, 2) NOT NULL,
    [LandedCostBefore]     DECIMAL (18, 6) NOT NULL,
    [LandedCostAfter]      DECIMAL (18, 6) NOT NULL
);
GO

ALTER TABLE [purchase].[LandedCostAdjustmentLines]
    ADD CONSTRAINT [FK_LandedCostAdjustmentLines_Line] FOREIGN KEY ([PurchaseLineId]) REFERENCES [purchase].[PurchaseDocumentLines] ([Id]);
GO

ALTER TABLE [purchase].[LandedCostAdjustmentLines]
    ADD CONSTRAINT [FK_LandedCostAdjustmentLines_Adj] FOREIGN KEY ([AdjustmentId]) REFERENCES [purchase].[LandedCostAdjustments] ([Id]);
GO

ALTER TABLE [purchase].[LandedCostAdjustmentLines]
    ADD CONSTRAINT [UQ_LandedCostAdjustmentLines] UNIQUE NONCLUSTERED ([AdjustmentId] ASC, [PurchaseLineId] ASC);
GO

ALTER TABLE [purchase].[LandedCostAdjustmentLines]
    ADD CONSTRAINT [PK_LandedCostAdjustmentLines] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

