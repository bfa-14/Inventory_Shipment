CREATE TABLE [logistics].[ContainerLines] (
    [Id]                   INT            IDENTITY (1, 1) NOT NULL,
    [ContainerId]          INT            NOT NULL,
    [LineNumber]           INT            NOT NULL,
    [PurchaseDocumentId]   INT            NOT NULL,
    [PurchaseLineId]       INT            NOT NULL,
    [ItemId]               INT            NOT NULL,
    [ItemUnitId]           INT            NOT NULL,
    [PackingFormula]       INT            NOT NULL,
    [Quantity]             INT            NOT NULL,
    [QuantityBase]         AS             ([Quantity]*[PackingFormula]) PERSISTED,
    [OilIncluded]          BIT            NOT NULL,
    [OilQtyPerUnit]        DECIMAL (9, 2) NULL,
    [TotalOilQty]          AS             (CONVERT([decimal](18,2),[Quantity]*isnull([OilQtyPerUnit],(0)))) PERSISTED,
    [ReceivedQuantityBase] INT            NULL,
    [VarianceReason]       NVARCHAR (200) NULL,
    [Notes]                NVARCHAR (300) NULL
);
GO

ALTER TABLE [logistics].[ContainerLines]
    ADD CONSTRAINT [FK_ContainerLines_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]);
GO

ALTER TABLE [logistics].[ContainerLines]
    ADD CONSTRAINT [FK_ContainerLines_Container] FOREIGN KEY ([ContainerId]) REFERENCES [logistics].[Containers] ([Id]);
GO

ALTER TABLE [logistics].[ContainerLines]
    ADD CONSTRAINT [FK_ContainerLines_Unit] FOREIGN KEY ([ItemUnitId]) REFERENCES [inventory].[ItemUnits] ([Id]);
GO

ALTER TABLE [logistics].[ContainerLines]
    ADD CONSTRAINT [FK_ContainerLines_Invoice] FOREIGN KEY ([PurchaseDocumentId]) REFERENCES [purchase].[PurchaseDocuments] ([Id]);
GO

ALTER TABLE [logistics].[ContainerLines]
    ADD CONSTRAINT [FK_ContainerLines_Line] FOREIGN KEY ([PurchaseLineId]) REFERENCES [purchase].[PurchaseDocumentLines] ([Id]);
GO

CREATE NONCLUSTERED INDEX [IX_ContainerLines_Container]
    ON [logistics].[ContainerLines]([ContainerId] ASC);
GO

CREATE NONCLUSTERED INDEX [IX_ContainerLines_Item]
    ON [logistics].[ContainerLines]([ItemId] ASC);
GO

CREATE NONCLUSTERED INDEX [IX_ContainerLines_Source]
    ON [logistics].[ContainerLines]([PurchaseLineId] ASC);
GO

ALTER TABLE [logistics].[ContainerLines]
    ADD CONSTRAINT [CK_ContainerLines_Received] CHECK ([ReceivedQuantityBase] IS NULL OR [ReceivedQuantityBase]>=(0));
GO

ALTER TABLE [logistics].[ContainerLines]
    ADD CONSTRAINT [CK_ContainerLines_Qty] CHECK ([Quantity]>(0));
GO

ALTER TABLE [logistics].[ContainerLines]
    ADD CONSTRAINT [UQ_ContainerLines_Source] UNIQUE NONCLUSTERED ([ContainerId] ASC, [PurchaseLineId] ASC);
GO

ALTER TABLE [logistics].[ContainerLines]
    ADD CONSTRAINT [UQ_ContainerLines_LineNo] UNIQUE NONCLUSTERED ([ContainerId] ASC, [LineNumber] ASC);
GO

ALTER TABLE [logistics].[ContainerLines]
    ADD CONSTRAINT [PK_ContainerLines] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

ALTER TABLE [logistics].[ContainerLines]
    ADD CONSTRAINT [DF_ContainerLines_Oil] DEFAULT ((0)) FOR [OilIncluded];
GO

