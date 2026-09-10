CREATE TYPE [sales].[tvp_InvoiceImportRow] AS TABLE (
    [RowNumber]       INT             NOT NULL,
    [ItemRef]         NVARCHAR (50)   NULL,
    [UnitName]        NVARCHAR (50)   NULL,
    [WarehouseRef]    NVARCHAR (150)  NULL,
    [Quantity]        DECIMAL (18, 3) NULL,
    [RawQuantity]     NVARCHAR (50)   NULL,
    [UnitPrice]       DECIMAL (18, 4) NULL,
    [DiscountPercent] DECIMAL (9, 4)  NULL,
    [ExpiryDate]      DATE            NULL,
    [RawExpiryDate]   NVARCHAR (50)   NULL,
    [Notes]           NVARCHAR (300)  NULL,
    PRIMARY KEY CLUSTERED ([RowNumber] ASC));

