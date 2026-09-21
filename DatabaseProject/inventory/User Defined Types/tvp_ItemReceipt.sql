CREATE TYPE [inventory].[tvp_ItemReceipt] AS TABLE (
    [ItemId]       INT             NOT NULL,
    [QuantityBase] INT             NOT NULL,
    [UnitCostBase] DECIMAL (18, 6) NOT NULL,
    [FobCostBase]  DECIMAL (18, 6) NULL);

