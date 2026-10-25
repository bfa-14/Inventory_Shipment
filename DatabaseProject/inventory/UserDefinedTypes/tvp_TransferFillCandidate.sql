CREATE TYPE [inventory].[tvp_TransferFillCandidate] AS TABLE (
    [Seq]                 INT NOT NULL,
    [ItemId]              INT NOT NULL,
    [ItemUnitId]          INT NOT NULL,
    [PackingFormula]      INT NOT NULL,
    [LineId]              INT NULL,
    [LineNumber]          INT NULL,
    [CurrentQuantity]     INT NULL,
    [CurrentQuantityBase] INT NULL,
    [OtherLinesBase]      INT NOT NULL,
    [OnOrder]             BIT NOT NULL,
    PRIMARY KEY CLUSTERED ([Seq] ASC));


GO

