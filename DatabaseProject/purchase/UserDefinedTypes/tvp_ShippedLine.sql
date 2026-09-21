CREATE TYPE [purchase].[tvp_ShippedLine] AS TABLE (
    [LineId]              INT NOT NULL,
    [ShippedQuantityBase] INT NOT NULL,
    PRIMARY KEY CLUSTERED ([LineId] ASC));
GO

