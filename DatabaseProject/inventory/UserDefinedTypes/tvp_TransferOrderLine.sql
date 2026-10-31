CREATE TYPE [inventory].[tvp_TransferOrderLine] AS TABLE (
    [LineNumber] INT            NOT NULL,
    [ItemId]     INT            NOT NULL,
    [ItemUnitId] INT            NOT NULL,
    [Quantity]   INT            NOT NULL,
    [Notes]      NVARCHAR (300) NULL,
    PRIMARY KEY CLUSTERED ([LineNumber] ASC));


GO

