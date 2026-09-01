CREATE TABLE [security].[RefreshTokens] (
    [Id]                  BIGINT         IDENTITY (1, 1) NOT NULL,
    [UserId]              INT            NOT NULL,
    [TokenHash]           NVARCHAR (64)  NOT NULL,
    [ExpiresAtUtc]        DATETIME2 (3)  NOT NULL,
    [CreatedAtUtc]        DATETIME2 (3)  CONSTRAINT [DF_RefreshTokens_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedByIp]         NVARCHAR (45)  NULL,
    [RevokedAtUtc]        DATETIME2 (3)  NULL,
    [RevokedByIp]         NVARCHAR (45)  NULL,
    [ReplacedByTokenHash] NVARCHAR (64)  NULL,
    [RevokeReason]        NVARCHAR (100) NULL,
    CONSTRAINT [PK_RefreshTokens] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_RefreshTokens_Users] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id]) ON DELETE CASCADE,
    CONSTRAINT [UQ_RefreshTokens_TokenHash] UNIQUE NONCLUSTERED ([TokenHash] ASC)
);


GO
CREATE NONCLUSTERED INDEX [IX_RefreshTokens_UserId]
    ON [security].[RefreshTokens]([UserId] ASC);

