CREATE TABLE [configuration].[SettingChanges] (
    [Id]           INT            IDENTITY (1, 1) NOT NULL,
    [SettingKey]   NVARCHAR (100) NOT NULL,
    [Action]       NVARCHAR (10)  NOT NULL,
    [OldValue]     NVARCHAR (400) NULL,
    [NewValue]     NVARCHAR (400) NULL,
    [ChangedAtUtc] DATETIME2 (3)  CONSTRAINT [DF_SettingChanges_ChangedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [ChangedBy]    INT            NULL,
    CONSTRAINT [PK_SettingChanges] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_SettingChanges_ChangedBy] FOREIGN KEY ([ChangedBy]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_SettingChanges_Key]
    ON [configuration].[SettingChanges]([SettingKey] ASC, [Id] DESC);


GO

