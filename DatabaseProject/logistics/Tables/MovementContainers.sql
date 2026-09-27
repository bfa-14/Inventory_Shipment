CREATE TABLE [logistics].[MovementContainers] (
    [Id]          INT IDENTITY (1, 1) NOT NULL,
    [MovementId]  INT NOT NULL,
    [ContainerId] INT NOT NULL,
    CONSTRAINT [PK_MovementContainers] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_MovementContainers_Container] FOREIGN KEY ([ContainerId]) REFERENCES [logistics].[Containers] ([Id]),
    CONSTRAINT [FK_MovementContainers_Movement] FOREIGN KEY ([MovementId]) REFERENCES [logistics].[Movements] ([Id]),
    CONSTRAINT [UQ_MovementContainers] UNIQUE NONCLUSTERED ([MovementId] ASC, [ContainerId] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_MovementContainers_Container]
    ON [logistics].[MovementContainers]([ContainerId] ASC);


GO

