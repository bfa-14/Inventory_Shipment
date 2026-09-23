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
    [CreatedAtUtc]     DATETIME2 (3)   CONSTRAINT [DF_ContainerFiles_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]        INT             NULL,
    CONSTRAINT [PK_ContainerFiles] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ContainerFiles_Size] CHECK ([SizeBytes]>(0)),
    CONSTRAINT [FK_ContainerFiles_Container] FOREIGN KEY ([ContainerId]) REFERENCES [logistics].[Containers] ([Id]),
    CONSTRAINT [FK_ContainerFiles_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ContainerFiles_Type] FOREIGN KEY ([AttachmentTypeId]) REFERENCES [masterdata].[AttachmentTypes] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_ContainerFiles_Container]
    ON [logistics].[ContainerFiles]([ContainerId] ASC);


GO

