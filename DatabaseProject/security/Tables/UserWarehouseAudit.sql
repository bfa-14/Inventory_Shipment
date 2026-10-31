CREATE TABLE [security].[UserWarehouseAudit] (
    [Id]           BIGINT          IDENTITY (1, 1) NOT NULL,
    [UserId]       INT             NOT NULL,
    [BeforeText]   NVARCHAR (1000) NOT NULL,
    [AfterText]    NVARCHAR (1000) NOT NULL,
    [ChangedBy]    INT             NULL,
    [ChangedAtUtc] DATETIME2 (3)   CONSTRAINT [DF_UserWarehouseAudit_ChangedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_UserWarehouseAudit] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_UserWarehouseAudit_Users] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id]) ON DELETE CASCADE
);


GO

CREATE NONCLUSTERED INDEX [IX_UserWarehouseAudit_User]
    ON [security].[UserWarehouseAudit]([UserId] ASC, [ChangedAtUtc] DESC);


GO

