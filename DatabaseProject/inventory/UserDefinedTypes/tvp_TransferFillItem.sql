CREATE TYPE [inventory].[tvp_TransferFillItem] AS TABLE (
    [ItemId]     INT NOT NULL,
    [ItemUnitId] INT NULL,
    PRIMARY KEY CLUSTERED ([ItemId] ASC));


GO

