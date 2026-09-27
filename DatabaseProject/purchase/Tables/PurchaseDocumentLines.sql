CREATE TABLE [purchase].[PurchaseDocumentLines] (
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
    [DiscountPercent]      DECIMAL (9, 4)  CONSTRAINT [DF_PurchaseDocumentLines_Discount] DEFAULT ((0)) NOT NULL,
    [LineDiscount]         AS              (CONVERT([decimal](18,2),(([Quantity]*[UnitPrice])*[DiscountPercent])/(100.0))) PERSISTED,
    [LineTotal]            AS              (CONVERT([decimal](18,2),([Quantity]*[UnitPrice])*((1)-[DiscountPercent]/(100.0)))) PERSISTED,
    [UnitCostBase]         DECIMAL (18, 6) NULL,
    [ReceivedQuantityBase] INT             CONSTRAINT [DF_PurchaseDocumentLines_Received] DEFAULT ((0)) NOT NULL,
    [ReturnedQuantityBase] INT             CONSTRAINT [DF_PurchaseDocumentLines_Returned] DEFAULT ((0)) NOT NULL,
    [ImportRowNumber]      INT             NULL,
    [Notes]                NVARCHAR (300)  NULL,
    [SourceLineId]         INT             NULL,
    [ShippedQuantityBase]  INT             CONSTRAINT [DF_PurchaseDocumentLines_Shipped] DEFAULT ((0)) NOT NULL,
    [FobCostBase]          DECIMAL (18, 6) NULL,
    [AllocatedChargesBase] DECIMAL (18, 2) CONSTRAINT [DF_PurchaseDocumentLines_Charges] DEFAULT ((0)) NOT NULL,
    [ContainerLineId]      INT             NULL,
    CONSTRAINT [PK_PurchaseDocumentLines] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_PurchaseDocumentLines_Discount] CHECK ([DiscountPercent]>=(0) AND [DiscountPercent]<=(100)),
    CONSTRAINT [CK_PurchaseDocumentLines_Formula] CHECK ([PackingFormula]>=(1)),
    CONSTRAINT [CK_PurchaseDocumentLines_Price] CHECK ([UnitPrice]>=(0)),
    CONSTRAINT [CK_PurchaseDocumentLines_Qty] CHECK ([Quantity]>(0)),
    CONSTRAINT [FK_PurchaseDocumentLines_ContainerLine] FOREIGN KEY ([ContainerLineId]) REFERENCES [logistics].[ContainerLines] ([Id]),
    CONSTRAINT [FK_PurchaseDocumentLines_Document] FOREIGN KEY ([DocumentId]) REFERENCES [purchase].[PurchaseDocuments] ([Id]),
    CONSTRAINT [FK_PurchaseDocumentLines_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]),
    CONSTRAINT [FK_PurchaseDocumentLines_ItemUnit] FOREIGN KEY ([ItemUnitId]) REFERENCES [inventory].[ItemUnits] ([Id]),
    CONSTRAINT [FK_PurchaseDocumentLines_SourceLine] FOREIGN KEY ([SourceLineId]) REFERENCES [purchase].[PurchaseDocumentLines] ([Id]),
    CONSTRAINT [FK_PurchaseDocumentLines_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]),
    CONSTRAINT [UQ_PurchaseDocumentLines_LineNo] UNIQUE NONCLUSTERED ([DocumentId] ASC, [LineNumber] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_PurchaseDocumentLines_Source]
    ON [purchase].[PurchaseDocumentLines]([SourceLineId] ASC) WHERE ([SourceLineId] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_PurchaseDocumentLines_Document]
    ON [purchase].[PurchaseDocumentLines]([DocumentId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_PurchaseDocumentLines_Item]
    ON [purchase].[PurchaseDocumentLines]([ItemId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_PurchaseDocumentLines_ContainerLine]
    ON [purchase].[PurchaseDocumentLines]([ContainerLineId] ASC) WHERE ([ContainerLineId] IS NOT NULL);


GO

