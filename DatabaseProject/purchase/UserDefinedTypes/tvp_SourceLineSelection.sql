CREATE TYPE [purchase].[tvp_SourceLineSelection] AS TABLE (
    [SourceLineId] INT NOT NULL,
    [QuantityBase] INT NOT NULL,
    PRIMARY KEY CLUSTERED ([SourceLineId] ASC));


GO

