CREATE TYPE [inventory].[tvp_ItemWarehouseLevelImport] AS TABLE (
    [RowNumber]       INT            NOT NULL,
    [ItemRef]         NVARCHAR (100) NULL,
    [WarehouseRef]    NVARCHAR (150) NULL,
    [MinQuantityBase] INT            NULL,
    [MaxQuantityBase] INT            NULL,
    [IsRemove]        BIT            NOT NULL,
    [ParseError]      NVARCHAR (300) NULL,
    PRIMARY KEY CLUSTERED ([RowNumber] ASC));


GO

