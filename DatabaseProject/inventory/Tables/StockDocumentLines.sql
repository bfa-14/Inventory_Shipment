CREATE TABLE [inventory].[StockDocumentLines] (
    [Id]             INT             IDENTITY (1, 1) NOT NULL,
    [DocumentId]     INT             NOT NULL,
    [LineNumber]     INT             NOT NULL,
    [ItemId]         INT             NOT NULL,
    [ItemUnitId]     INT             NOT NULL,
    [WarehouseId]    INT             NOT NULL,
    [ExpiryDate]     DATE            NULL,
    [Quantity]       INT             NOT NULL,
    [PackingFormula] INT             NOT NULL,
    [QuantityBase]   AS              ([Quantity]*[PackingFormula]) PERSISTED,
    [UnitCost]       DECIMAL (18, 4) NOT NULL,
    [LineTotal]      AS              (CONVERT([decimal](18,2),[Quantity]*[UnitCost])) PERSISTED,
    [Notes]          NVARCHAR (300)  NULL,
    [SourceLineId]   INT             NULL
);
GO

ALTER TABLE [inventory].[StockDocumentLines]
    ADD CONSTRAINT [CK_StockDocumentLines_Qty] CHECK ([Quantity]>(0));
GO

ALTER TABLE [inventory].[StockDocumentLines]
    ADD CONSTRAINT [CK_StockDocumentLines_Cost] CHECK ([UnitCost]>=(0));
GO

ALTER TABLE [inventory].[StockDocumentLines]
    ADD CONSTRAINT [CK_StockDocumentLines_Formula] CHECK ([PackingFormula]>=(1));
GO

ALTER TABLE [inventory].[StockDocumentLines]
    ADD CONSTRAINT [DF_StockDocumentLines_UnitCost] DEFAULT ((0)) FOR [UnitCost];
GO

CREATE NONCLUSTERED INDEX [IX_StockDocumentLines_Item]
    ON [inventory].[StockDocumentLines]([ItemId] ASC);
GO

CREATE NONCLUSTERED INDEX [IX_StockDocumentLines_Document]
    ON [inventory].[StockDocumentLines]([DocumentId] ASC);
GO

ALTER TABLE [inventory].[StockDocumentLines]
    ADD CONSTRAINT [UQ_StockDocumentLines_LineNo] UNIQUE NONCLUSTERED ([DocumentId] ASC, [LineNumber] ASC);
GO

ALTER TABLE [inventory].[StockDocumentLines]
    ADD CONSTRAINT [FK_StockDocumentLines_Document] FOREIGN KEY ([DocumentId]) REFERENCES [inventory].[StockDocuments] ([Id]);
GO

ALTER TABLE [inventory].[StockDocumentLines]
    ADD CONSTRAINT [FK_StockDocumentLines_ItemUnit] FOREIGN KEY ([ItemUnitId]) REFERENCES [inventory].[ItemUnits] ([Id]);
GO

ALTER TABLE [inventory].[StockDocumentLines]
    ADD CONSTRAINT [FK_StockDocumentLines_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]);
GO

ALTER TABLE [inventory].[StockDocumentLines]
    ADD CONSTRAINT [FK_StockDocumentLines_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]);
GO

ALTER TABLE [inventory].[StockDocumentLines]
    ADD CONSTRAINT [PK_StockDocumentLines] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

