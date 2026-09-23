CREATE TABLE [logistics].[ContainerInvoices] (
    [Id]                 INT IDENTITY (1, 1) NOT NULL,
    [ContainerId]        INT NOT NULL,
    [PurchaseDocumentId] INT NOT NULL,
    CONSTRAINT [PK_ContainerInvoices] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_ContainerInvoices_Container] FOREIGN KEY ([ContainerId]) REFERENCES [logistics].[Containers] ([Id]),
    CONSTRAINT [FK_ContainerInvoices_Invoice] FOREIGN KEY ([PurchaseDocumentId]) REFERENCES [purchase].[PurchaseDocuments] ([Id]),
    CONSTRAINT [UQ_ContainerInvoices] UNIQUE NONCLUSTERED ([ContainerId] ASC, [PurchaseDocumentId] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_ContainerInvoices_Invoice]
    ON [logistics].[ContainerInvoices]([PurchaseDocumentId] ASC);


GO

