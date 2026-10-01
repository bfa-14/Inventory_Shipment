CREATE TABLE [configuration].[SettingValues] (
    [SettingKey]   NVARCHAR (100) NOT NULL,
    [Value]        NVARCHAR (400) NOT NULL,
    [UpdatedAtUtc] DATETIME2 (3)  CONSTRAINT [DF_SettingValues_UpdatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [UpdatedBy]    INT            NULL,
    CONSTRAINT [PK_SettingValues] PRIMARY KEY CLUSTERED ([SettingKey] ASC),
    CONSTRAINT [FK_SettingValues_Definitions] FOREIGN KEY ([SettingKey]) REFERENCES [configuration].[SettingDefinitions] ([SettingKey]) ON DELETE CASCADE,
    CONSTRAINT [FK_SettingValues_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id])
);


GO

