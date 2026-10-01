CREATE TABLE [sales].[ReceiptAllocations] (
    [Id]                    INT             IDENTITY (1, 1) NOT NULL,
    [ReceiptId]             INT             NOT NULL,
    [SalesDocumentId]       INT             NOT NULL,
    [AmountInvoiceCurrency] DECIMAL (18, 2) NOT NULL,
    [InvoiceExchangeRate]   DECIMAL (18, 6) NOT NULL,
    [AmountBase]            AS              (CONVERT([decimal](18,2),[AmountInvoiceCurrency]/[InvoiceExchangeRate])) PERSISTED,
    [AllocatedAtUtc]        DATETIME2 (3)   CONSTRAINT [DF_ReceiptAllocations_At] DEFAULT (sysutcdatetime()) NOT NULL,
    [AllocatedBy]           INT             NULL,
    [RemovedAtUtc]          DATETIME2 (3)   NULL,
    [RemovedBy]             INT             NULL,
    CONSTRAINT [PK_ReceiptAllocations] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ReceiptAllocations_Amount] CHECK ([AmountInvoiceCurrency]>(0)),
    CONSTRAINT [CK_ReceiptAllocations_Rate] CHECK ([InvoiceExchangeRate]>(0)),
    CONSTRAINT [CK_ReceiptAllocations_Removed] CHECK ([RemovedAtUtc] IS NULL AND [RemovedBy] IS NULL OR [RemovedAtUtc] IS NOT NULL AND [RemovedBy] IS NOT NULL),
    CONSTRAINT [FK_ReceiptAllocations_By] FOREIGN KEY ([AllocatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ReceiptAllocations_Invoice] FOREIGN KEY ([SalesDocumentId]) REFERENCES [sales].[SalesDocuments] ([Id]),
    CONSTRAINT [FK_ReceiptAllocations_Receipt] FOREIGN KEY ([ReceiptId]) REFERENCES [sales].[Receipts] ([Id]),
    CONSTRAINT [FK_ReceiptAllocations_RemovedBy] FOREIGN KEY ([RemovedBy]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_ReceiptAllocations_Invoice]
    ON [sales].[ReceiptAllocations]([SalesDocumentId] ASC)
    INCLUDE([ReceiptId], [AmountInvoiceCurrency], [RemovedAtUtc]);


GO

CREATE NONCLUSTERED INDEX [IX_ReceiptAllocations_Receipt]
    ON [sales].[ReceiptAllocations]([ReceiptId] ASC);


GO

