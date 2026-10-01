CREATE TYPE [logistics].[tvp_ItemCapacity] AS TABLE (
    [ItemId]          INT NOT NULL,
    [PcsPerContainer] INT NOT NULL,
    PRIMARY KEY CLUSTERED ([ItemId] ASC));


GO

