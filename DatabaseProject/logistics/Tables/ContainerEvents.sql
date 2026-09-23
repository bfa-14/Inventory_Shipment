CREATE TABLE [logistics].[ContainerEvents] (
    [Id]           BIGINT         IDENTITY (1, 1) NOT NULL,
    [ContainerId]  INT            NOT NULL,
    [EventType]    NVARCHAR (20)  NOT NULL,
    [EventDate]    DATE           NOT NULL,
    [PortId]       INT            NULL,
    [LocationText] NVARCHAR (100) NULL,
    [Notes]        NVARCHAR (300) NULL,
    [CreatedAtUtc] DATETIME2 (3)  CONSTRAINT [DF_ContainerEvents_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]    INT            NULL,
    CONSTRAINT [PK_ContainerEvents] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ContainerEvents_Type] CHECK ([EventType]=N'Note' OR [EventType]=N'Offloaded' OR [EventType]=N'BorderCrossing' OR [EventType]=N'CustomsRelease' OR [EventType]=N'PortArrival' OR [EventType]=N'Dispatched' OR [EventType]=N'Booked'),
    CONSTRAINT [FK_ContainerEvents_Container] FOREIGN KEY ([ContainerId]) REFERENCES [logistics].[Containers] ([Id]),
    CONSTRAINT [FK_ContainerEvents_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ContainerEvents_Port] FOREIGN KEY ([PortId]) REFERENCES [masterdata].[Ports] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_ContainerEvents_Container]
    ON [logistics].[ContainerEvents]([ContainerId] ASC, [EventDate] ASC, [Id] ASC);


GO

