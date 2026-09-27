CREATE TYPE [purchase].[tvp_LineContainer] AS TABLE (
    [LineNumber]      INT NOT NULL,
    [ContainerLineId] INT NOT NULL,
    PRIMARY KEY CLUSTERED ([LineNumber] ASC));


GO

