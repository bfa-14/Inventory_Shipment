CREATE TYPE [purchase].[tvp_ManualAllocation] AS TABLE (
    [ChargeLineNumber] INT             NOT NULL,
    [PurchaseLineId]   INT             NOT NULL,
    [AmountBase]       DECIMAL (18, 2) NOT NULL,
    PRIMARY KEY CLUSTERED ([ChargeLineNumber] ASC, [PurchaseLineId] ASC));
GO

