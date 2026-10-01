CREATE TYPE [logistics].[tvp_ContainerPlanLine] AS TABLE (
    [Seq]          INT NOT NULL,
    [PoLineId]     INT NOT NULL,
    [QuantityBase] INT NOT NULL,
    [OilIncluded]  BIT NULL,
    PRIMARY KEY CLUSTERED ([Seq] ASC, [PoLineId] ASC));


GO

