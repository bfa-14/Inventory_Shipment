CREATE TABLE [logistics].[ContainerFiles] (
    [Id]               INT             IDENTITY (1, 1) NOT NULL,
    [ContainerId]      INT             NOT NULL,
    [AttachmentTypeId] INT             NULL,
    [FileName]         NVARCHAR (255)  NOT NULL,
    [ContentType]      NVARCHAR (100)  NOT NULL,
    [SizeBytes]        INT             NOT NULL,
    [Content]          VARBINARY (MAX) NOT NULL,
    [Note]             NVARCHAR (300)  NULL,
    [DocumentDate]     DATE            NULL,
    [CreatedAtUtc]     DATETIME2 (3)   NOT NULL,
    [CreatedBy]        INT             NULL
);
GO

ALTER TABLE [logistics].[ContainerFiles]
    ADD CONSTRAINT [PK_ContainerFiles] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

ALTER TABLE [logistics].[ContainerFiles]
    ADD CONSTRAINT [DF_ContainerFiles_CreatedAtUtc] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];
GO

CREATE NONCLUSTERED INDEX [IX_ContainerFiles_Container]
    ON [logistics].[ContainerFiles]([ContainerId] ASC);
GO

ALTER TABLE [logistics].[ContainerFiles]
    ADD CONSTRAINT [FK_ContainerFiles_Container] FOREIGN KEY ([ContainerId]) REFERENCES [logistics].[Containers] ([Id]);
GO

ALTER TABLE [logistics].[ContainerFiles]
    ADD CONSTRAINT [FK_ContainerFiles_Type] FOREIGN KEY ([AttachmentTypeId]) REFERENCES [masterdata].[AttachmentTypes] ([Id]);
GO

ALTER TABLE [logistics].[ContainerFiles]
    ADD CONSTRAINT [FK_ContainerFiles_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [logistics].[ContainerFiles]
    ADD CONSTRAINT [CK_ContainerFiles_Size] CHECK ([SizeBytes]>(0));
GO

