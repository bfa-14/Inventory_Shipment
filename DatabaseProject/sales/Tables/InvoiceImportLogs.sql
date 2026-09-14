CREATE TABLE [sales].[InvoiceImportLogs] (
    [Id]             INT            IDENTITY (1, 1) NOT NULL,
    [InvoiceId]      INT            NULL,
    [DraftReference] NVARCHAR (50)  NULL,
    [BranchId]       INT            NOT NULL,
    [WarehouseId]    INT            NOT NULL,
    [PriceListId]    INT            NULL,
    [FileName]       NVARCHAR (255) NOT NULL,
    [TotalRows]      INT            NOT NULL,
    [ImportedRows]   INT            NOT NULL,
    [WarningRows]    INT            NOT NULL,
    [RejectedRows]   INT            NOT NULL,
    [ImportedBy]     INT            NULL,
    [ImportedAtUtc]  DATETIME2 (3)  CONSTRAINT [DF_InvoiceImportLogs_ImportedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_InvoiceImportLogs] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_InvoiceImportLogs_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_InvoiceImportLogs_Invoice] FOREIGN KEY ([InvoiceId]) REFERENCES [sales].[SalesDocuments] ([Id]),
    CONSTRAINT [FK_InvoiceImportLogs_PriceList] FOREIGN KEY ([PriceListId]) REFERENCES [masterdata].[PriceLists] ([Id]),
    CONSTRAINT [FK_InvoiceImportLogs_User] FOREIGN KEY ([ImportedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_InvoiceImportLogs_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id])
);




GO
CREATE NONCLUSTERED INDEX [IX_InvoiceImportLogs_Invoice]
    ON [sales].[InvoiceImportLogs]([InvoiceId] ASC);

