CREATE TABLE [security].[LoginAudit] (
    [Id]             BIGINT         IDENTITY (1, 1) NOT NULL,
    [Username]       NVARCHAR (256) NOT NULL,
    [UserId]         INT            NULL,
    [Succeeded]      BIT            NOT NULL,
    [FailureReason]  NVARCHAR (100) NULL,
    [IpAddress]      NVARCHAR (45)  NULL,
    [UserAgent]      NVARCHAR (512) NULL,
    [AttemptedAtUtc] DATETIME2 (3)  CONSTRAINT [DF_LoginAudit_AttemptedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_LoginAudit] PRIMARY KEY CLUSTERED ([Id] ASC)
);


GO
CREATE NONCLUSTERED INDEX [IX_LoginAudit_Username_AttemptedAtUtc]
    ON [security].[LoginAudit]([Username] ASC, [AttemptedAtUtc] DESC);

