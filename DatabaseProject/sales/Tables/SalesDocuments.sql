CREATE TABLE [sales].[SalesDocuments] (
    [Id]                   INT             IDENTITY (1, 1) NOT NULL,
    [DocumentTypeId]       INT             NOT NULL,
    [DocumentNumber]       NVARCHAR (30)   NULL,
    [DocumentDate]         DATE            NOT NULL,
    [DueDate]              DATE            NULL,
    [BranchId]             INT             NOT NULL,
    [WarehouseId]          INT             NOT NULL,
    [ClientId]             INT             NOT NULL,
    [SalesmanId]           INT             NULL,
    [PriceListId]          INT             NOT NULL,
    [CurrencyId]           INT             NOT NULL,
    [RateType]             TINYINT         CONSTRAINT [DF_SalesDocuments_RateType] DEFAULT ((1)) NOT NULL,
    [ExchangeRate]         DECIMAL (18, 6) CONSTRAINT [DF_SalesDocuments_Rate] DEFAULT ((1)) NOT NULL,
    [ReferenceNo]          NVARCHAR (100)  NULL,
    [Notes]                NVARCHAR (1000) NULL,
    [Status]               TINYINT         CONSTRAINT [DF_SalesDocuments_Status] DEFAULT ((1)) NOT NULL,
    [TotalItems]           INT             CONSTRAINT [DF_SalesDocuments_TotalItems] DEFAULT ((0)) NOT NULL,
    [TotalQuantity]        INT             CONSTRAINT [DF_SalesDocuments_TotalQuantity] DEFAULT ((0)) NOT NULL,
    [Subtotal]             DECIMAL (18, 2) CONSTRAINT [DF_SalesDocuments_Subtotal] DEFAULT ((0)) NOT NULL,
    [TotalDiscount]        DECIMAL (18, 2) CONSTRAINT [DF_SalesDocuments_TotalDiscount] DEFAULT ((0)) NOT NULL,
    [TotalAmount]          DECIMAL (18, 2) CONSTRAINT [DF_SalesDocuments_TotalAmount] DEFAULT ((0)) NOT NULL,
    [TotalAmountBase]      DECIMAL (18, 2) CONSTRAINT [DF_SalesDocuments_TotalAmountBase] DEFAULT ((0)) NOT NULL,
    [TotalCostBase]        DECIMAL (18, 2) CONSTRAINT [DF_SalesDocuments_TotalCostBase] DEFAULT ((0)) NOT NULL,
    [SourceDocumentId]     INT             NULL,
    [PostedAtUtc]          DATETIME2 (3)   NULL,
    [PostedBy]             INT             NULL,
    [CancelledAtUtc]       DATETIME2 (3)   NULL,
    [CancelledBy]          INT             NULL,
    [CancelReason]         NVARCHAR (300)  NULL,
    [CreatedAtUtc]         DATETIME2 (3)   CONSTRAINT [DF_SalesDocuments_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]            INT             NULL,
    [UpdatedAtUtc]         DATETIME2 (3)   NULL,
    [UpdatedBy]            INT             NULL,
    [RowVersion]           ROWVERSION      NOT NULL,
    [TotalGrossProfitBase] DECIMAL (18, 2) CONSTRAINT [DF_SalesDocuments_GrossProfit] DEFAULT ((0)) NOT NULL,
    CONSTRAINT [PK_SalesDocuments] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_SalesDocuments_DueDate] CHECK ([DueDate] IS NULL OR [DueDate]>=[DocumentDate]),
    CONSTRAINT [CK_SalesDocuments_Rate] CHECK ([ExchangeRate]>(0)),
    CONSTRAINT [CK_SalesDocuments_RateType] CHECK ([RateType]=(3) OR [RateType]=(2) OR [RateType]=(1)),
    CONSTRAINT [CK_SalesDocuments_Status] CHECK ([Status]=(3) OR [Status]=(2) OR [Status]=(1)),
    CONSTRAINT [FK_SalesDocuments_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_SalesDocuments_CancelledBy] FOREIGN KEY ([CancelledBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_SalesDocuments_Client] FOREIGN KEY ([ClientId]) REFERENCES [masterdata].[Parties] ([Id]),
    CONSTRAINT [FK_SalesDocuments_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_SalesDocuments_Currency] FOREIGN KEY ([CurrencyId]) REFERENCES [masterdata].[Currencies] ([Id]),
    CONSTRAINT [FK_SalesDocuments_PostedBy] FOREIGN KEY ([PostedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_SalesDocuments_PriceList] FOREIGN KEY ([PriceListId]) REFERENCES [masterdata].[PriceLists] ([Id]),
    CONSTRAINT [FK_SalesDocuments_Salesman] FOREIGN KEY ([SalesmanId]) REFERENCES [masterdata].[Parties] ([Id]),
    CONSTRAINT [FK_SalesDocuments_Source] FOREIGN KEY ([SourceDocumentId]) REFERENCES [sales].[SalesDocuments] ([Id]),
    CONSTRAINT [FK_SalesDocuments_Type] FOREIGN KEY ([DocumentTypeId]) REFERENCES [inventory].[DocumentTypes] ([Id]),
    CONSTRAINT [FK_SalesDocuments_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_SalesDocuments_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_SalesDocuments_TypeStatus]
    ON [sales].[SalesDocuments]([DocumentTypeId] ASC, [Status] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_SalesDocuments_TypeDate]
    ON [sales].[SalesDocuments]([DocumentTypeId] ASC, [DocumentDate] DESC);


GO

CREATE NONCLUSTERED INDEX [IX_SalesDocuments_Salesman]
    ON [sales].[SalesDocuments]([SalesmanId] ASC) WHERE ([SalesmanId] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_SalesDocuments_Client]
    ON [sales].[SalesDocuments]([ClientId] ASC, [DocumentDate] DESC);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_SalesDocuments_Number]
    ON [sales].[SalesDocuments]([DocumentNumber] ASC) WHERE ([DocumentNumber] IS NOT NULL);


GO

