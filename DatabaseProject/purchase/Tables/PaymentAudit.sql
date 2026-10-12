CREATE TABLE [purchase].[PaymentAudit] (
    [Id]        BIGINT         IDENTITY (1, 1) NOT NULL,
    [PaymentId] INT            NOT NULL,
    [Action]    NVARCHAR (20)  NOT NULL,
    [Details]   NVARCHAR (500) NULL,
    [UserId]    INT            NULL,
    [AtUtc]     DATETIME2 (3)  CONSTRAINT [DF_PaymentAudit_AtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    CONSTRAINT [PK_PaymentAudit] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_PaymentAudit_Payment] FOREIGN KEY ([PaymentId]) REFERENCES [purchase].[Payments] ([Id]),
    CONSTRAINT [FK_PaymentAudit_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_PaymentAudit_Payment]
    ON [purchase].[PaymentAudit]([PaymentId] ASC, [AtUtc] DESC);


GO

