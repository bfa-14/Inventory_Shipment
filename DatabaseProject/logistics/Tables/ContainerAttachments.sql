CREATE TABLE [logistics].[ContainerAttachments] (
    [Id]               INT              IDENTITY (1, 1) NOT NULL,
    [ContainerId]      INT              NOT NULL,
    [MovementId]       INT              NULL,
    [ChargeId]         INT              NULL,
    [AttachmentTypeId] INT              NULL,
    [FileId]           INT              NOT NULL,
    [Note]             NVARCHAR (300)   NULL,
    [DocumentDate]     DATE             NULL,
    [GroupId]          UNIQUEIDENTIFIER NULL,
    [CreatedAtUtc]     DATETIME2 (3)    CONSTRAINT [DF_ContainerAttachments_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]        INT              NULL,
    CONSTRAINT [PK_ContainerAttachments] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_ContainerAttachments_Charge] FOREIGN KEY ([ChargeId]) REFERENCES [logistics].[ContainerCharges] ([Id]),
    CONSTRAINT [FK_ContainerAttachments_Container] FOREIGN KEY ([ContainerId]) REFERENCES [logistics].[Containers] ([Id]),
    CONSTRAINT [FK_ContainerAttachments_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ContainerAttachments_File] FOREIGN KEY ([FileId]) REFERENCES [logistics].[Files] ([Id]),
    CONSTRAINT [FK_ContainerAttachments_Movement] FOREIGN KEY ([MovementId]) REFERENCES [logistics].[Movements] ([Id]),
    CONSTRAINT [FK_ContainerAttachments_Type] FOREIGN KEY ([AttachmentTypeId]) REFERENCES [masterdata].[AttachmentTypes] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_ContainerAttachments_Movement]
    ON [logistics].[ContainerAttachments]([MovementId] ASC) WHERE ([MovementId] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_ContainerAttachments_Charge]
    ON [logistics].[ContainerAttachments]([ChargeId] ASC) WHERE ([ChargeId] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_ContainerAttachments_File]
    ON [logistics].[ContainerAttachments]([FileId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_ContainerAttachments_Container]
    ON [logistics].[ContainerAttachments]([ContainerId] ASC);


GO

