CREATE TABLE [configuration].[SettingDefinitions] (
    [SettingKey]   NVARCHAR (100)  NOT NULL,
    [GroupName]    NVARCHAR (60)   NOT NULL,
    [Label]        NVARCHAR (150)  NOT NULL,
    [Description]  NVARCHAR (500)  NULL,
    [ValueType]    NVARCHAR (10)   NOT NULL,
    [DefaultValue] NVARCHAR (400)  NOT NULL,
    [MinValue]     DECIMAL (18, 4) NULL,
    [MaxValue]     DECIMAL (18, 4) NULL,
    [IsPublic]     BIT             CONSTRAINT [DF_SettingDefinitions_IsPublic] DEFAULT ((0)) NOT NULL,
    [SortOrder]    INT             CONSTRAINT [DF_SettingDefinitions_SortOrder] DEFAULT ((100)) NOT NULL,
    CONSTRAINT [PK_SettingDefinitions] PRIMARY KEY CLUSTERED ([SettingKey] ASC),
    CONSTRAINT [CK_SettingDefinitions_Key_NotBlank] CHECK (len(ltrim(rtrim([SettingKey])))>(0)),
    CONSTRAINT [CK_SettingDefinitions_ValueType] CHECK ([ValueType]=N'text' OR [ValueType]=N'decimal' OR [ValueType]=N'int' OR [ValueType]=N'bool')
);


GO

