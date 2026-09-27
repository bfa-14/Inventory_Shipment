CREATE TYPE [logistics].[tvp_ContainerLineQty] AS TABLE (
    [ContainerLineId] INT NOT NULL,
    [QuantityBase]    INT NOT NULL,
    PRIMARY KEY CLUSTERED ([ContainerLineId] ASC));


GO

