CREATE TABLE [logistics].[ContainerAudit] (
    [Id]          BIGINT         IDENTITY (1, 1) NOT NULL,
    [ContainerId] INT            NOT NULL,
    [Action]      NVARCHAR (20)  NOT NULL,
    [Details]     NVARCHAR (500) NULL,
    [UserId]      INT            NULL,
    [AtUtc]       DATETIME2 (3)  NOT NULL
);
GO

ALTER TABLE [logistics].[ContainerAudit]
    ADD CONSTRAINT [FK_ContainerAudit_User] FOREIGN KEY ([UserId]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [logistics].[ContainerAudit]
    ADD CONSTRAINT [FK_ContainerAudit_Container] FOREIGN KEY ([ContainerId]) REFERENCES [logistics].[Containers] ([Id]);
GO

ALTER TABLE [logistics].[ContainerAudit]
    ADD CONSTRAINT [DF_ContainerAudit_AtUtc] DEFAULT (sysutcdatetime()) FOR [AtUtc];
GO

ALTER TABLE [logistics].[ContainerAudit]
    ADD CONSTRAINT [PK_ContainerAudit] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

CREATE NONCLUSTERED INDEX [IX_ContainerAudit_Container]
    ON [logistics].[ContainerAudit]([ContainerId] ASC, [AtUtc] ASC);
GO

