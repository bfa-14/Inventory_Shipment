CREATE TABLE [security].[UserRoles] (
    [UserId]        INT           NOT NULL,
    [RoleId]        INT           NOT NULL,
    [AssignedAtUtc] DATETIME2 (3) CONSTRAINT [DF_UserRoles_AssignedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [AssignedBy]    INT           NULL,
    CONSTRAINT [PK_UserRoles] PRIMARY KEY CLUSTERED ([UserId] ASC, [RoleId] ASC),
    CONSTRAINT [FK_UserRoles_Roles] FOREIGN KEY ([RoleId]) REFERENCES [security].[Roles] ([Id]) ON DELETE CASCADE,
    CONSTRAINT [FK_UserRoles_Users] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id]) ON DELETE CASCADE
);


GO
CREATE NONCLUSTERED INDEX [IX_UserRoles_RoleId]
    ON [security].[UserRoles]([RoleId] ASC);

