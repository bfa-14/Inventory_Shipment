CREATE TYPE [sales].[tvp_SalesDocumentLine] AS TABLE (
    [LineNumber]      INT             NOT NULL,
    [ItemId]          INT             NOT NULL,
    [ItemUnitId]      INT             NOT NULL,
    [WarehouseId]     INT             NOT NULL,
    [Specification]   NVARCHAR (100)  NULL,
    [ExpiryDate]      DATE            NULL,
    [Quantity]        INT             NOT NULL,
    [UnitPrice]       DECIMAL (18, 4) NULL,
    [DiscountPercent] DECIMAL (9, 4)  NULL,
    [ImportRowNumber] INT             NULL,
    [Notes]           NVARCHAR (300)  NULL,
    PRIMARY KEY CLUSTERED ([LineNumber] ASC));


GO

