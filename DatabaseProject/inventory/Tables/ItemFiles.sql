CREATE TABLE [inventory].[ItemFiles] (
    [Id]               INT             IDENTITY (1, 1) NOT NULL,
    [ItemId]           INT             NOT NULL,
    [FileName]         NVARCHAR (255)  NOT NULL,
    [ContentType]      NVARCHAR (100)  NOT NULL,
    [SizeBytes]        INT             NOT NULL,
    [IsItemImage]      BIT             CONSTRAINT [DF_ItemFiles_IsItemImage] DEFAULT ((0)) NOT NULL,
    [Content]          VARBINARY (MAX) NOT NULL,
    [CreatedAtUtc]     DATETIME2 (3)   CONSTRAINT [DF_ItemFiles_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]        INT             NULL,
    [AttachmentTypeId] INT             NULL,
    [DocumentDate]     DATE            NULL,
    [Note]             NVARCHAR (500)  NULL,
    CONSTRAINT [PK_ItemFiles] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ItemFiles_Size] CHECK ([SizeBytes]>(0)),
    CONSTRAINT [CK_ItemFiles_Type] CHECK ([IsItemImage]=(1) OR [AttachmentTypeId] IS NOT NULL),
    CONSTRAINT [FK_ItemFiles_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ItemFiles_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]),
    CONSTRAINT [FK_ItemFiles_Type] FOREIGN KEY ([AttachmentTypeId]) REFERENCES [masterdata].[AttachmentTypes] ([Id])
);




GO

CREATE NONCLUSTERED INDEX [IX_ItemFiles_Item]
    ON [inventory].[ItemFiles]([ItemId] ASC);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_ItemFiles_ItemImage]
    ON [inventory].[ItemFiles]([ItemId] ASC) WHERE ([IsItemImage]=(1));


GO
CREATE NONCLUSTERED INDEX [IX_ItemFiles_Report]
    ON [inventory].[ItemFiles]([DocumentDate] ASC, [CreatedAtUtc] ASC)
    INCLUDE([ItemId], [IsItemImage], [AttachmentTypeId], [FileName], [ContentType], [SizeBytes], [CreatedBy]);

