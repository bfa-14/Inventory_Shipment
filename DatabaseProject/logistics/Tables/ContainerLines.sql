CREATE TABLE [logistics].[ContainerLines] (
    [Id]                   INT             IDENTITY (1, 1) NOT NULL,
    [ContainerId]          INT             NOT NULL,
    [LineNumber]           INT             NOT NULL,
    [PurchaseDocumentId]   INT             NULL,
    [PurchaseLineId]       INT             NULL,
    [ItemId]               INT             NOT NULL,
    [ItemUnitId]           INT             NOT NULL,
    [PackingFormula]       INT             NOT NULL,
    [Quantity]             INT             NOT NULL,
    [QuantityBase]         AS              ([Quantity]*[PackingFormula]) PERSISTED,
    [OilIncluded]          BIT             CONSTRAINT [DF_ContainerLines_Oil] DEFAULT ((0)) NOT NULL,
    [OilQtyPerUnit]        DECIMAL (9, 2)  NULL,
    [TotalOilQty]          AS              (CONVERT([decimal](18,2),[Quantity]*isnull([OilQtyPerUnit],(0)))) PERSISTED,
    [ReceivedQuantityBase] INT             NULL,
    [VarianceReason]       NVARCHAR (200)  NULL,
    [Notes]                NVARCHAR (300)  NULL,
    [PurchaseOrderId]      INT             NOT NULL,
    [PoLineId]             INT             NOT NULL,
    [FobCostBase]          DECIMAL (18, 6) NULL,
    [ChargesBase]          DECIMAL (18, 2) CONSTRAINT [DF_ContainerLines_Charges] DEFAULT ((0)) NOT NULL,
    [LandedCostBase]       DECIMAL (18, 6) NULL,
    CONSTRAINT [PK_ContainerLines] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ContainerLines_Qty] CHECK ([Quantity]>(0)),
    CONSTRAINT [CK_ContainerLines_Received] CHECK ([ReceivedQuantityBase] IS NULL OR [ReceivedQuantityBase]>=(0)),
    CONSTRAINT [FK_ContainerLines_Container] FOREIGN KEY ([ContainerId]) REFERENCES [logistics].[Containers] ([Id]),
    CONSTRAINT [FK_ContainerLines_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]),
    CONSTRAINT [FK_ContainerLines_Order] FOREIGN KEY ([PurchaseOrderId]) REFERENCES [purchase].[PurchaseDocuments] ([Id]),
    CONSTRAINT [FK_ContainerLines_PoLine] FOREIGN KEY ([PoLineId]) REFERENCES [purchase].[PurchaseDocumentLines] ([Id]),
    CONSTRAINT [FK_ContainerLines_Unit] FOREIGN KEY ([ItemUnitId]) REFERENCES [inventory].[ItemUnits] ([Id]),
    CONSTRAINT [UQ_ContainerLines_LineNo] UNIQUE NONCLUSTERED ([ContainerId] ASC, [LineNumber] ASC),
    CONSTRAINT [UQ_ContainerLines_PoLine] UNIQUE NONCLUSTERED ([ContainerId] ASC, [PoLineId] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_ContainerLines_Item]
    ON [logistics].[ContainerLines]([ItemId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_ContainerLines_Order]
    ON [logistics].[ContainerLines]([PurchaseOrderId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_ContainerLines_Container]
    ON [logistics].[ContainerLines]([ContainerId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_ContainerLines_PoLine]
    ON [logistics].[ContainerLines]([PoLineId] ASC);


GO

