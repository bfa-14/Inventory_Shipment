CREATE TABLE [sales].[Receipts] (
    [Id]                    INT             IDENTITY (1, 1) NOT NULL,
    [ReceiptNumber]         NVARCHAR (30)   NULL,
    [ReceiptDate]           DATE            NOT NULL,
    [ClientId]              INT             NOT NULL,
    [BranchId]              INT             NOT NULL,
    [PaymentType]           TINYINT         CONSTRAINT [DF_Receipts_PaymentType] DEFAULT ((1)) NOT NULL,
    [CurrencyId]            INT             NOT NULL,
    [Amount]                DECIMAL (18, 2) NOT NULL,
    [ExchangeRate]          DECIMAL (18, 6) CONSTRAINT [DF_Receipts_Rate] DEFAULT ((1)) NOT NULL,
    [AmountBase]            AS              (CONVERT([decimal](18,2),[Amount]/[ExchangeRate])) PERSISTED,
    [Notes]                 NVARCHAR (1000) NULL,
    [Status]                TINYINT         CONSTRAINT [DF_Receipts_Status] DEFAULT ((1)) NOT NULL,
    [PostedAtUtc]           DATETIME2 (3)   NULL,
    [PostedBy]              INT             NULL,
    [ReversedAtUtc]         DATETIME2 (3)   NULL,
    [ReversedBy]            INT             NULL,
    [ReverseReason]         NVARCHAR (500)  NULL,
    [CreatedAtUtc]          DATETIME2 (3)   CONSTRAINT [DF_Receipts_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]             INT             NULL,
    [UpdatedAtUtc]          DATETIME2 (3)   NULL,
    [UpdatedBy]             INT             NULL,
    [RowVersion]            ROWVERSION      NOT NULL,
    [SourceSalesDocumentId] INT             NULL,
    CONSTRAINT [PK_Receipts] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_Receipts_Amount] CHECK ([Amount]>(0)),
    CONSTRAINT [CK_Receipts_PaymentType] CHECK ([PaymentType]=(2) OR [PaymentType]=(1)),
    CONSTRAINT [CK_Receipts_Rate] CHECK ([ExchangeRate]>(0)),
    CONSTRAINT [CK_Receipts_Reversal] CHECK ([Status]<>(3) OR [ReversedAtUtc] IS NOT NULL AND [ReversedBy] IS NOT NULL),
    CONSTRAINT [CK_Receipts_Status] CHECK ([Status]=(3) OR [Status]=(2) OR [Status]=(1)),
    CONSTRAINT [FK_Receipts_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_Receipts_Client] FOREIGN KEY ([ClientId]) REFERENCES [masterdata].[Parties] ([Id]),
    CONSTRAINT [FK_Receipts_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Receipts_Currency] FOREIGN KEY ([CurrencyId]) REFERENCES [masterdata].[Currencies] ([Id]),
    CONSTRAINT [FK_Receipts_PostedBy] FOREIGN KEY ([PostedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Receipts_ReversedBy] FOREIGN KEY ([ReversedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Receipts_SourceSalesDocument] FOREIGN KEY ([SourceSalesDocumentId]) REFERENCES [sales].[SalesDocuments] ([Id]),
    CONSTRAINT [FK_Receipts_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_Receipts_SourceSalesDocument]
    ON [sales].[Receipts]([SourceSalesDocumentId] ASC) WHERE ([SourceSalesDocumentId] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_Receipts_Status]
    ON [sales].[Receipts]([Status] ASC, [ReceiptDate] DESC);


GO

CREATE NONCLUSTERED INDEX [IX_Receipts_Client]
    ON [sales].[Receipts]([ClientId] ASC, [ReceiptDate] DESC);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_Receipts_Number]
    ON [sales].[Receipts]([ReceiptNumber] ASC) WHERE ([ReceiptNumber] IS NOT NULL);


GO

