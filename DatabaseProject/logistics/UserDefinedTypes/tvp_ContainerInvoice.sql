CREATE TYPE [logistics].[tvp_ContainerInvoice] AS TABLE (
    [PurchaseDocumentId] INT NOT NULL,
    PRIMARY KEY CLUSTERED ([PurchaseDocumentId] ASC));
GO

