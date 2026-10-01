CREATE TYPE [sales].[tvp_ReceiptAllocation] AS TABLE (
    [SalesDocumentId] INT             NOT NULL,
    [Amount]          DECIMAL (18, 2) NOT NULL,
    PRIMARY KEY CLUSTERED ([SalesDocumentId] ASC));


GO

