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
    [ImportedAtUtc]  DATETIME2 (3)  NOT NULL
);
GO

ALTER TABLE [sales].[InvoiceImportLogs]
    ADD CONSTRAINT [FK_InvoiceImportLogs_Warehouse] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]);
GO

ALTER TABLE [sales].[InvoiceImportLogs]
    ADD CONSTRAINT [FK_InvoiceImportLogs_Invoice] FOREIGN KEY ([InvoiceId]) REFERENCES [sales].[SalesDocuments] ([Id]);
GO

ALTER TABLE [sales].[InvoiceImportLogs]
    ADD CONSTRAINT [FK_InvoiceImportLogs_PriceList] FOREIGN KEY ([PriceListId]) REFERENCES [masterdata].[PriceLists] ([Id]);
GO

ALTER TABLE [sales].[InvoiceImportLogs]
    ADD CONSTRAINT [FK_InvoiceImportLogs_User] FOREIGN KEY ([ImportedBy]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [sales].[InvoiceImportLogs]
    ADD CONSTRAINT [FK_InvoiceImportLogs_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]);
GO

ALTER TABLE [sales].[InvoiceImportLogs]
    ADD CONSTRAINT [PK_InvoiceImportLogs] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

CREATE NONCLUSTERED INDEX [IX_InvoiceImportLogs_Invoice]
    ON [sales].[InvoiceImportLogs]([InvoiceId] ASC);
GO

ALTER TABLE [sales].[InvoiceImportLogs]
    ADD CONSTRAINT [DF_InvoiceImportLogs_ImportedAtUtc] DEFAULT (sysutcdatetime()) FOR [ImportedAtUtc];
GO

