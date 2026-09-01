CREATE TABLE [security].[Users] (
    [Id]                  INT            IDENTITY (1, 1) NOT NULL,
    [Username]            NVARCHAR (50)  NOT NULL,
    [Email]               NVARCHAR (256) NOT NULL,
    [FullName]            NVARCHAR (100) NOT NULL,
    [PasswordHash]        NVARCHAR (512) NOT NULL,
    [IsActive]            BIT            CONSTRAINT [DF_Users_IsActive] DEFAULT ((1)) NOT NULL,
    [FailedLoginAttempts] INT            CONSTRAINT [DF_Users_FailedLoginAttempts] DEFAULT ((0)) NOT NULL,
    [LockoutEndUtc]       DATETIME2 (3)  NULL,
    [LastLoginAtUtc]      DATETIME2 (3)  NULL,
    [CreatedAtUtc]        DATETIME2 (3)  CONSTRAINT [DF_Users_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [UpdatedAtUtc]        DATETIME2 (3)  NULL,
    CONSTRAINT [PK_Users] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [UQ_Users_Email] UNIQUE NONCLUSTERED ([Email] ASC),
    CONSTRAINT [UQ_Users_Username] UNIQUE NONCLUSTERED ([Username] ASC)
);

