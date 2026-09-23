CREATE TYPE [logistics].[tvp_ContainerLine] AS TABLE (
    [LineNumber]     INT            NOT NULL,
    [PurchaseLineId] INT            NOT NULL,
    [Quantity]       INT            NOT NULL,
    [OilIncluded]    BIT            NOT NULL,
    [OilQtyPerUnit]  DECIMAL (9, 2) NULL,
    [Notes]          NVARCHAR (300) NULL,
    PRIMARY KEY CLUSTERED ([LineNumber] ASC));
GO

