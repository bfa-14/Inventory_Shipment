CREATE TABLE [sales].[SalesDocumentLines] (
    [Id]                   INT             IDENTITY (1, 1) NOT NULL,
    [DocumentId]           INT             NOT NULL,
    [LineNumber]           INT             NOT NULL,
    [ItemId]               INT             NOT NULL,
    [ItemUnitId]           INT             NOT NULL,
    [WarehouseId]          INT             NOT NULL,
    [ExpiryDate]           DATE            NULL,
    [Quantity]             INT             NOT NULL,
    [PackingFormula]       INT             NOT NULL,
    [QuantityBase]         AS              ([Quantity]*[PackingFormula]) PERSISTED,
    [UnitPrice]            DECIMAL (18, 4) NOT NULL,
    [DiscountPercent]      DECIMAL (9, 4)  NOT NULL,
    [LineDiscount]         AS              (CONVERT([decimal](18,2),(([Quantity]*[UnitPrice])*[DiscountPercent])/(100.0))) PERSISTED,
    [LineTotal]            AS              (CONVERT([decimal](18,2),([Quantity]*[UnitPrice])*((1)-[DiscountPercent]/(100.0)))) PERSISTED,
    [PriceSource]          NVARCHAR (20)   NOT NULL,
    [UnitCostBase]         DECIMAL (18, 6) NULL,
    [ImportRowNumber]      INT             NULL,
    [Notes]                NVARCHAR (300)  NULL,
    [SourceLineId]         INT             NULL,
    [FobCostAtSale]        DECIMAL (18, 6) NULL,
    [LastCostAtSale]       DECIMAL (18, 6) NULL,
    [NetSalesBase]         DECIMAL (18, 2) NULL,
    [CogsBase]             DECIMAL (18, 2) NULL,
    [GrossProfitBase]      DECIMAL (18, 2) NULL,
    [GrossProfitPct]       DECIMAL (9, 2)  NULL,
    [ReturnedQuantityBase] INT             NOT NULL
);
GO

CREATE NONCLUSTERED INDEX [IX_SalesDocumentLines_Document]
    ON [sales].[SalesDocumentLines]([DocumentId] ASC);
GO

CREATE NONCLUSTERED INDEX [IX_SalesDocumentLines_Item]
    ON [sales].[SalesDocumentLines]([ItemId] ASC);
GO

ALTER TABLE [sales].[SalesDocumentLines]
    ADD CONSTRAINT [FK_SalesDocumentLines_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]);
GO

ALTER TABLE [sales].[SalesDocumentLines]
    ADD CONSTRAINT [FK_SalesDocumentLines_ItemUnit] FOREIGN KEY ([ItemUnitId]) REFERENCES [inventory].[ItemUnits] ([Id]);
GO

ALTER TABLE [sales].[SalesDocumentLines]
    ADD CONSTRAINT [FK_SalesDocumentLines_Document] FOREIGN KEY ([DocumentId]) REFERENCES [sales].[SalesDocuments] ([Id]);
GO

ALTER TABLE [sales].[SalesDocumentLines]
    ADD CONSTRAINT [FK_SalesDocumentLines_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]);
GO

ALTER TABLE [sales].[SalesDocumentLines]
    ADD CONSTRAINT [DF_SalesDocumentLines_Discount] DEFAULT ((0)) FOR [DiscountPercent];
GO

ALTER TABLE [sales].[SalesDocumentLines]
    ADD CONSTRAINT [DF_SalesDocumentLines_PriceSource] DEFAULT (N'PriceList') FOR [PriceSource];
GO

ALTER TABLE [sales].[SalesDocumentLines]
    ADD CONSTRAINT [DF_SalesDocumentLines_Returned] DEFAULT ((0)) FOR [ReturnedQuantityBase];
GO

ALTER TABLE [sales].[SalesDocumentLines]
    ADD CONSTRAINT [CK_SalesDocumentLines_Discount] CHECK ([DiscountPercent]>=(0) AND [DiscountPercent]<=(100));
GO

ALTER TABLE [sales].[SalesDocumentLines]
    ADD CONSTRAINT [CK_SalesDocumentLines_Qty] CHECK ([Quantity]>(0));
GO

ALTER TABLE [sales].[SalesDocumentLines]
    ADD CONSTRAINT [CK_SalesDocumentLines_PriceSource] CHECK ([PriceSource]=N'Manual' OR [PriceSource]=N'PriceList');
GO

ALTER TABLE [sales].[SalesDocumentLines]
    ADD CONSTRAINT [CK_SalesDocumentLines_Formula] CHECK ([PackingFormula]>=(1));
GO

ALTER TABLE [sales].[SalesDocumentLines]
    ADD CONSTRAINT [CK_SalesDocumentLines_Price] CHECK ([UnitPrice]>=(0));
GO

ALTER TABLE [sales].[SalesDocumentLines]
    ADD CONSTRAINT [UQ_SalesDocumentLines_LineNo] UNIQUE NONCLUSTERED ([DocumentId] ASC, [LineNumber] ASC);
GO

ALTER TABLE [sales].[SalesDocumentLines]
    ADD CONSTRAINT [PK_SalesDocumentLines] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

