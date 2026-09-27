CREATE TYPE [logistics].[tvp_ChargeManual] AS TABLE (
    [ContainerLineId] INT             NOT NULL,
    [AmountBase]      DECIMAL (18, 2) NOT NULL,
    PRIMARY KEY CLUSTERED ([ContainerLineId] ASC));


GO

