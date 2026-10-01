CREATE TABLE [sales].[OutOfStockSaleAudit] (
    [Id]              BIGINT        IDENTITY (1, 1) NOT NULL,
    [SalesDocumentId] INT           NOT NULL,
    [DocumentNumber]  NVARCHAR (30) NOT NULL,
    [ItemId]          INT           NOT NULL,
    [ItemCode]        NVARCHAR (30) NOT NULL,
    [WarehouseId]     INT           NOT NULL,
    [QuantitySold]    INT           NOT NULL,
    [StockBefore]     INT           NOT NULL,
    [InventoryAfter]  INT           NOT NULL,
    [SoldAtUtc]       DATETIME2 (3) CONSTRAINT [DF_OutOfStockSaleAudit_SoldAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [UserId]          INT           NULL,
    [SaleStatus]      NVARCHAR (30) CONSTRAINT [DF_OutOfStockSaleAudit_SaleStatus] DEFAULT (N'OutOfStockOverride') NOT NULL,
    [PolicySource]    NVARCHAR (10) NOT NULL,
    CONSTRAINT [PK_OutOfStockSaleAudit] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_OutOfStockSaleAudit_Document] FOREIGN KEY ([SalesDocumentId]) REFERENCES [sales].[SalesDocuments] ([Id]),
    CONSTRAINT [FK_OutOfStockSaleAudit_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]),
    CONSTRAINT [FK_OutOfStockSaleAudit_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_OutOfStockSaleAudit_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_OutOfStockSaleAudit_Warehouse]
    ON [sales].[OutOfStockSaleAudit]([WarehouseId] ASC, [SoldAtUtc] DESC);


GO

CREATE NONCLUSTERED INDEX [IX_OutOfStockSaleAudit_Document]
    ON [sales].[OutOfStockSaleAudit]([SalesDocumentId] ASC);


GO

