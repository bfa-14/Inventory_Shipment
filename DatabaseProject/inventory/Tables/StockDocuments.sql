CREATE TABLE [inventory].[StockDocuments] (
    [Id]             INT             IDENTITY (1, 1) NOT NULL,
    [DocumentTypeId] INT             NOT NULL,
    [DocumentNumber] NVARCHAR (30)   NULL,
    [DocumentDate]   DATE            NOT NULL,
    [BranchId]       INT             NOT NULL,
    [WarehouseId]    INT             NOT NULL,
    [ReasonId]       INT             NULL,
    [ReferenceNo]    NVARCHAR (100)  NULL,
    [CurrencyId]     INT             NOT NULL,
    [ExchangeRate]   DECIMAL (18, 6) CONSTRAINT [DF_StockDocuments_Rate] DEFAULT ((1)) NOT NULL,
    [Notes]          NVARCHAR (1000) NULL,
    [Status]         TINYINT         CONSTRAINT [DF_StockDocuments_Status] DEFAULT ((1)) NOT NULL,
    [TotalItems]     INT             CONSTRAINT [DF_StockDocuments_TotalItems] DEFAULT ((0)) NOT NULL,
    [TotalQuantity]  INT             CONSTRAINT [DF_StockDocuments_TotalQuantity] DEFAULT ((0)) NOT NULL,
    [TotalCost]      DECIMAL (18, 2) CONSTRAINT [DF_StockDocuments_TotalCost] DEFAULT ((0)) NOT NULL,
    [PostedAtUtc]    DATETIME2 (3)   NULL,
    [PostedBy]       INT             NULL,
    [CancelledAtUtc] DATETIME2 (3)   NULL,
    [CancelledBy]    INT             NULL,
    [CancelReason]   NVARCHAR (300)  NULL,
    [CreatedAtUtc]   DATETIME2 (3)   CONSTRAINT [DF_StockDocuments_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]      INT             NULL,
    [UpdatedAtUtc]   DATETIME2 (3)   NULL,
    [UpdatedBy]      INT             NULL,
    [RowVersion]     ROWVERSION      NOT NULL,
    CONSTRAINT [PK_StockDocuments] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_StockDocuments_Status] CHECK ([Status]=(3) OR [Status]=(2) OR [Status]=(1)),
    CONSTRAINT [FK_StockDocuments_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_StockDocuments_CancelledBy] FOREIGN KEY ([CancelledBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_StockDocuments_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_StockDocuments_Currency] FOREIGN KEY ([CurrencyId]) REFERENCES [masterdata].[Currencies] ([Id]),
    CONSTRAINT [FK_StockDocuments_PostedBy] FOREIGN KEY ([PostedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_StockDocuments_Reason] FOREIGN KEY ([ReasonId]) REFERENCES [inventory].[StockReasons] ([Id]),
    CONSTRAINT [FK_StockDocuments_Type] FOREIGN KEY ([DocumentTypeId]) REFERENCES [inventory].[DocumentTypes] ([Id]),
    CONSTRAINT [FK_StockDocuments_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_StockDocuments_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_StockDocuments_TypeDate]
    ON [inventory].[StockDocuments]([DocumentTypeId] ASC, [DocumentDate] DESC);


GO

CREATE NONCLUSTERED INDEX [IX_StockDocuments_TypeStatus]
    ON [inventory].[StockDocuments]([DocumentTypeId] ASC, [Status] ASC);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_StockDocuments_Number]
    ON [inventory].[StockDocuments]([DocumentNumber] ASC) WHERE ([DocumentNumber] IS NOT NULL);


GO

