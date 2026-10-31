CREATE TABLE [security].[UserWarehouses] (
    [UserId]       INT           NOT NULL,
    [WarehouseId]  INT           NOT NULL,
    [GrantedAtUtc] DATETIME2 (3) CONSTRAINT [DF_UserWarehouses_GrantedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [GrantedBy]    INT           NULL,
    CONSTRAINT [PK_UserWarehouses] PRIMARY KEY CLUSTERED ([UserId] ASC, [WarehouseId] ASC),
    CONSTRAINT [FK_UserWarehouses_Users] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id]) ON DELETE CASCADE,
    CONSTRAINT [FK_UserWarehouses_Warehouses] FOREIGN KEY ([WarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]) ON DELETE CASCADE
);


GO

CREATE NONCLUSTERED INDEX [IX_UserWarehouses_WarehouseId]
    ON [security].[UserWarehouses]([WarehouseId] ASC);


GO

