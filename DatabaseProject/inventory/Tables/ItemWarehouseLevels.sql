CREATE TABLE [inventory].[ItemWarehouseLevels] (
    [ItemId]          INT           NOT NULL,
    [WarehouseId]     INT           NOT NULL,
    [MinQuantityBase] INT           NOT NULL,
    [MaxQuantityBase] INT           NULL,
    [CreatedAtUtc]    DATETIME2 (3) CONSTRAINT [DF_ItemWarehouseLevels_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]       INT           NULL,
    [UpdatedAtUtc]    DATETIME2 (3) CONSTRAINT [DF_ItemWarehouseLevels_UpdatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [UpdatedBy]       INT           NULL,
    [RowVersion]      ROWVERSION    NOT NULL,
    CONSTRAINT [PK_ItemWarehouseLevels] PRIMARY KEY CLUSTERED ([ItemId] ASC, [WarehouseId] ASC),
    CONSTRAINT [CK_ItemWarehouseLevels_Max] CHECK ([MaxQuantityBase] IS NULL OR [MaxQuantityBase]>=[MinQuantityBase]),
    CONSTRAINT [CK_ItemWarehouseLevels_Min] CHECK ([MinQuantityBase]>=(0)),
    CONSTRAINT [CK_ItemWarehouseLevels_Range] CHECK ([MinQuantityBase]<=(1000000000) AND ([MaxQuantityBase] IS NULL OR [MaxQuantityBase]<=(1000000000))),
    CONSTRAINT [FK_ItemWarehouseLevels_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ItemWarehouseLevels_Items] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]) ON DELETE CASCADE,
    CONSTRAINT [FK_ItemWarehouseLevels_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ItemWarehouseLevels_Warehouses] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]) ON DELETE CASCADE
);


GO

CREATE NONCLUSTERED INDEX [IX_ItemWarehouseLevels_Warehouse]
    ON [inventory].[ItemWarehouseLevels]([WarehouseId] ASC)
    INCLUDE([MinQuantityBase], [MaxQuantityBase]);


GO

