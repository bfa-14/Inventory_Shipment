CREATE TABLE [purchase].[GoodsReceiptInvoiceMatches] (
    [GoodsReceiptLineId] INT           NOT NULL,
    [InvoiceLineId]      INT           NOT NULL,
    [QuantityBase]       INT           NOT NULL,
    [MatchedAtUtc]       DATETIME2 (3) CONSTRAINT [DF_GoodsReceiptInvoiceMatches_At] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_GoodsReceiptInvoiceMatches] PRIMARY KEY CLUSTERED ([GoodsReceiptLineId] ASC, [InvoiceLineId] ASC),
    CONSTRAINT [CK_GoodsReceiptInvoiceMatches_Qty] CHECK ([QuantityBase]>(0)),
    CONSTRAINT [FK_GoodsReceiptInvoiceMatches_InvoiceLine] FOREIGN KEY ([InvoiceLineId]) REFERENCES [purchase].[PurchaseDocumentLines] ([Id]),
    CONSTRAINT [FK_GoodsReceiptInvoiceMatches_Line] FOREIGN KEY ([GoodsReceiptLineId]) REFERENCES [purchase].[GoodsReceiptLines] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_GoodsReceiptInvoiceMatches_InvoiceLine]
    ON [purchase].[GoodsReceiptInvoiceMatches]([InvoiceLineId] ASC)
    INCLUDE([QuantityBase]);


GO

