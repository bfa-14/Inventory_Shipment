CREATE TYPE [inventory].[tvp_ItemWarehouseLevel] AS TABLE (
    [WarehouseId]     INT        NOT NULL,
    [MinQuantityBase] INT        NULL,
    [MaxQuantityBase] INT        NULL,
    [RowVersion]      BINARY (8) NULL,
    PRIMARY KEY CLUSTERED ([WarehouseId] ASC));


GO

