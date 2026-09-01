CREATE TABLE [security].[RolePermissions] (
    [RoleId]       INT           NOT NULL,
    [PermissionId] INT           NOT NULL,
    [GrantedAtUtc] DATETIME2 (3) CONSTRAINT [DF_RolePermissions_GrantedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_RolePermissions] PRIMARY KEY CLUSTERED ([RoleId] ASC, [PermissionId] ASC),
    CONSTRAINT [FK_RolePermissions_Permissions] FOREIGN KEY ([PermissionId]) REFERENCES [security].[Permissions] ([Id]) ON DELETE CASCADE,
    CONSTRAINT [FK_RolePermissions_Roles] FOREIGN KEY ([RoleId]) REFERENCES [security].[Roles] ([Id]) ON DELETE CASCADE
);


GO
CREATE NONCLUSTERED INDEX [IX_RolePermissions_PermissionId]
    ON [security].[RolePermissions]([PermissionId] ASC);

