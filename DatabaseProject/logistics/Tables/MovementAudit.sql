CREATE TABLE [logistics].[MovementAudit] (
    [Id]         INT             IDENTITY (1, 1) NOT NULL,
    [MovementId] INT             NOT NULL,
    [Action]     NVARCHAR (30)   NOT NULL,
    [Details]    NVARCHAR (1000) NULL,
    [UserId]     INT             NULL,
    [AtUtc]      DATETIME2 (3)   CONSTRAINT [DF_MovementAudit_AtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_MovementAudit] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_MovementAudit_Movement] FOREIGN KEY ([MovementId]) REFERENCES [logistics].[Movements] ([Id]),
    CONSTRAINT [FK_MovementAudit_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_MovementAudit_Movement]
    ON [logistics].[MovementAudit]([MovementId] ASC, [AtUtc] ASC);


GO

