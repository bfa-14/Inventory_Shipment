CREATE TYPE [inventory].[tvp_ItemPortCost] AS TABLE (
    [PortId]   INT             NOT NULL,
    [CostBase] DECIMAL (18, 2) NULL,
    PRIMARY KEY CLUSTERED ([PortId] ASC));


GO

