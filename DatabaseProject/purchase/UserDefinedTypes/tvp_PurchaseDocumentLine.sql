CREATE TYPE [purchase].[tvp_PurchaseDocumentLine] AS TABLE (
    [LineNumber]      INT             NOT NULL,
    [ItemId]          INT             NOT NULL,
    [ItemUnitId]      INT             NOT NULL,
    [WarehouseId]     INT             NOT NULL,
    [ExpiryDate]      DATE            NULL,
    [Quantity]        INT             NOT NULL,
    [UnitPrice]       DECIMAL (18, 4) NULL,
    [DiscountPercent] DECIMAL (9, 4)  NULL,
    [ImportRowNumber] INT             NULL,
    [Notes]           NVARCHAR (300)  NULL,
    [SourceLineId]    INT             NULL,
    PRIMARY KEY CLUSTERED ([LineNumber] ASC));


GO

