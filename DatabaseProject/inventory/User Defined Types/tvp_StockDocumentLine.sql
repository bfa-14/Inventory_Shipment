CREATE TYPE [inventory].[tvp_StockDocumentLine] AS TABLE (
    [LineNumber]  INT             NOT NULL,
    [ItemId]      INT             NOT NULL,
    [ItemUnitId]  INT             NOT NULL,
    [WarehouseId] INT             NOT NULL,
    [ExpiryDate]  DATE            NULL,
    [Quantity]    INT             NOT NULL,
    [UnitCost]    DECIMAL (18, 4) NULL,
    [Notes]       NVARCHAR (300)  NULL,
    PRIMARY KEY CLUSTERED ([LineNumber] ASC));

