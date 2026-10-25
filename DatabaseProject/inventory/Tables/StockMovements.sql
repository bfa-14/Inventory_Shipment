CREATE TABLE [inventory].[StockMovements] (
    [Id]               BIGINT          IDENTITY (1, 1) NOT NULL,
    [MovementDate]     DATETIME2 (3)   NOT NULL,
    [ItemId]           INT             NOT NULL,
    [WarehouseId]      INT             NOT NULL,
    [BranchId]         INT             NOT NULL,
    [QuantityBase]     INT             NOT NULL,
    [UnitCostBase]     DECIMAL (18, 6) NULL,
    [DocumentFamily]   NVARCHAR (20)   NOT NULL,
    [DocumentTypeCode] NVARCHAR (20)   NOT NULL,
    [DocumentId]       INT             NOT NULL,
    [DocumentLineId]   INT             NOT NULL,
    [DocumentNumber]   NVARCHAR (30)   NOT NULL,
    [ReasonCode]       NVARCHAR (20)   NULL,
    [ExpiryDate]       DATE            NULL,
    [IsReversal]       BIT             CONSTRAINT [DF_StockMovements_IsReversal] DEFAULT ((0)) NOT NULL,
    [CreatedAtUtc]     DATETIME2 (3)   CONSTRAINT [DF_StockMovements_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]        INT             NULL,
    CONSTRAINT [PK_StockMovements] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_StockMovements_Qty] CHECK ([QuantityBase]<>(0)),
    CONSTRAINT [FK_StockMovements_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_StockMovements_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_StockMovements_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]),
    CONSTRAINT [FK_StockMovements_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_StockMovements_WarehouseDate]
    ON [inventory].[StockMovements]([WarehouseId] ASC, [MovementDate] ASC)
    INCLUDE([ItemId], [QuantityBase]);


GO

CREATE NONCLUSTERED INDEX [IX_StockMovements_Document]
    ON [inventory].[StockMovements]([DocumentFamily] ASC, [DocumentId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_StockMovements_ItemWarehouseDate]
    ON [inventory].[StockMovements]([ItemId] ASC, [WarehouseId] ASC, [MovementDate] ASC)
    INCLUDE([QuantityBase], [UnitCostBase]);


GO

