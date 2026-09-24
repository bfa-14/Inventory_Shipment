CREATE TABLE [security].[Roles] (
    [Id]           INT            IDENTITY (1, 1) NOT NULL,
    [Name]         NVARCHAR (50)  NOT NULL,
    [Description]  NVARCHAR (250) NULL,
    [IsSystem]     BIT            CONSTRAINT [DF_Roles_IsSystem] DEFAULT ((0)) NOT NULL,
    [IsActive]     BIT            CONSTRAINT [DF_Roles_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)  CONSTRAINT [DF_Roles_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [UpdatedAtUtc] DATETIME2 (3)  NULL,
    CONSTRAINT [PK_Roles] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [UQ_Roles_Name] UNIQUE NONCLUSTERED ([Name] ASC)
);


GO

