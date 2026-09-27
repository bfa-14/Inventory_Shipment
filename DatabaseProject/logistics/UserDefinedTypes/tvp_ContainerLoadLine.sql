CREATE TYPE [logistics].[tvp_ContainerLoadLine] AS TABLE (
    [LineNumber]    INT            NOT NULL,
    [PoLineId]      INT            NOT NULL,
    [QuantityBase]  INT            NOT NULL,
    [OilIncluded]   BIT            NOT NULL,
    [OilQtyPerUnit] DECIMAL (9, 2) NULL,
    [Notes]         NVARCHAR (300) NULL,
    PRIMARY KEY CLUSTERED ([LineNumber] ASC));


GO

