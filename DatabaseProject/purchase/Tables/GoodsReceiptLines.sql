CREATE TABLE [purchase].[GoodsReceiptLines] (
    [Id]                   INT             IDENTITY (1, 1) NOT NULL,
    [GoodsReceiptId]       INT             NOT NULL,
    [LineNumber]           INT             NOT NULL,
    [ItemId]               INT             NOT NULL,
    [ItemUnitId]           INT             NOT NULL,
    [Quantity]             INT             NOT NULL,
    [PackingFormula]       INT             NOT NULL,
    [QuantityBase]         AS              ([Quantity]*[PackingFormula]) PERSISTED,
    [ExpectedQuantityBase] INT             NULL,
    [VarianceReasonCode]   NVARCHAR (20)   NULL,
    [VarianceReason]       NVARCHAR (300)  NULL,
    [CloseShort]           BIT             CONSTRAINT [DF_GoodsReceiptLines_CloseShort] DEFAULT ((0)) NOT NULL,
    [SettledShortBase]     INT             CONSTRAINT [DF_GoodsReceiptLines_Settled] DEFAULT ((0)) NOT NULL,
    [WarehouseId]          INT             NULL,
    [SupplierId]           INT             NULL,
    [PurchaseOrderId]      INT             NULL,
    [PoLineId]             INT             NULL,
    [InvoiceLineId]        INT             NULL,
    [ContainerLineId]      INT             NULL,
    [ExpiryDate]           DATE            NULL,
    [PoFobBase]            DECIMAL (18, 6) NULL,
    [ManualUnitCostBase]   DECIMAL (18, 6) NULL,
    [FobCostBase]          DECIMAL (18, 6) NULL,
    [ChargesBase]          DECIMAL (18, 6) NULL,
    [UnitCostBase]         DECIMAL (18, 6) NULL,
    [CostAtReceiptBase]    DECIMAL (18, 6) NULL,
    [CostSource]           NVARCHAR (10)   NULL,
    [InvoicedBase]         INT             CONSTRAINT [DF_GoodsReceiptLines_Invoiced] DEFAULT ((0)) NOT NULL,
    [Notes]                NVARCHAR (300)  NULL,
    CONSTRAINT [PK_GoodsReceiptLines] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_GoodsReceiptLines_Container] CHECK ([ContainerLineId] IS NULL OR [PoLineId] IS NOT NULL),
    CONSTRAINT [CK_GoodsReceiptLines_CostSource] CHECK ([CostSource] IS NULL OR ([CostSource]=N'Manual' OR [CostSource]=N'Mixed' OR [CostSource]=N'Invoice' OR [CostSource]=N'Order')),
    CONSTRAINT [CK_GoodsReceiptLines_Expected] CHECK ([ExpectedQuantityBase] IS NULL OR [ExpectedQuantityBase]>=(0)),
    CONSTRAINT [CK_GoodsReceiptLines_Formula] CHECK ([PackingFormula]>=(1)),
    CONSTRAINT [CK_GoodsReceiptLines_Invoiced] CHECK ([InvoicedBase]>=(0) AND [InvoicedBase]<=[Quantity]*[PackingFormula]),
    CONSTRAINT [CK_GoodsReceiptLines_ManualCost] CHECK ([ManualUnitCostBase] IS NULL OR [ManualUnitCostBase]>=(0)),
    CONSTRAINT [CK_GoodsReceiptLines_Order] CHECK ([PoLineId] IS NULL AND [PurchaseOrderId] IS NULL OR [PoLineId] IS NOT NULL AND [PurchaseOrderId] IS NOT NULL),
    CONSTRAINT [CK_GoodsReceiptLines_Qty] CHECK ([Quantity]>=(0)),
    CONSTRAINT [CK_GoodsReceiptLines_Reason] CHECK ([VarianceReasonCode] IS NULL OR ([VarianceReasonCode]=N'OTHER' OR [VarianceReasonCode]=N'LOADCOUNT' OR [VarianceReasonCode]=N'MISSING' OR [VarianceReasonCode]=N'DAMAGED' OR [VarianceReasonCode]=N'SHORT')),
    CONSTRAINT [CK_GoodsReceiptLines_Settled] CHECK ([SettledShortBase]>=(0)),
    CONSTRAINT [FK_GoodsReceiptLines_ContainerLine] FOREIGN KEY ([ContainerLineId]) REFERENCES [logistics].[ContainerLines] ([Id]),
    CONSTRAINT [FK_GoodsReceiptLines_InvoiceLine] FOREIGN KEY ([InvoiceLineId]) REFERENCES [purchase].[PurchaseDocumentLines] ([Id]),
    CONSTRAINT [FK_GoodsReceiptLines_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]),
    CONSTRAINT [FK_GoodsReceiptLines_Order] FOREIGN KEY ([PurchaseOrderId]) REFERENCES [purchase].[PurchaseDocuments] ([Id]),
    CONSTRAINT [FK_GoodsReceiptLines_PoLine] FOREIGN KEY ([PoLineId]) REFERENCES [purchase].[PurchaseDocumentLines] ([Id]),
    CONSTRAINT [FK_GoodsReceiptLines_Receipt] FOREIGN KEY ([GoodsReceiptId]) REFERENCES [purchase].[GoodsReceipts] ([Id]),
    CONSTRAINT [FK_GoodsReceiptLines_Supplier] FOREIGN KEY ([SupplierId]) REFERENCES [masterdata].[Parties] ([Id]),
    CONSTRAINT [FK_GoodsReceiptLines_Unit] FOREIGN KEY ([ItemUnitId]) REFERENCES [inventory].[ItemUnits] ([Id]),
    CONSTRAINT [FK_GoodsReceiptLines_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]),
    CONSTRAINT [UQ_GoodsReceiptLines_LineNo] UNIQUE NONCLUSTERED ([GoodsReceiptId] ASC, [LineNumber] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_GoodsReceiptLines_PoLine]
    ON [purchase].[GoodsReceiptLines]([PoLineId] ASC)
    INCLUDE([GoodsReceiptId], [ContainerLineId], [QuantityBase]) WHERE ([PoLineId] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_GoodsReceiptLines_SupplierItem]
    ON [purchase].[GoodsReceiptLines]([SupplierId] ASC, [ItemId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_GoodsReceiptLines_ContainerLine]
    ON [purchase].[GoodsReceiptLines]([ContainerLineId] ASC)
    INCLUDE([GoodsReceiptId]) WHERE ([ContainerLineId] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_GoodsReceiptLines_Item]
    ON [purchase].[GoodsReceiptLines]([ItemId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_GoodsReceiptLines_InvoiceLine]
    ON [purchase].[GoodsReceiptLines]([InvoiceLineId] ASC)
    INCLUDE([GoodsReceiptId], [QuantityBase]) WHERE ([InvoiceLineId] IS NOT NULL);


GO

