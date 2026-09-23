CREATE TABLE [inventory].[ItemFiles] (
    [Id]           INT             IDENTITY (1, 1) NOT NULL,
    [ItemId]       INT             NOT NULL,
    [FileName]     NVARCHAR (255)  NOT NULL,
    [ContentType]  NVARCHAR (100)  NOT NULL,
    [SizeBytes]    INT             NOT NULL,
    [IsItemImage]  BIT             CONSTRAINT [DF_ItemFiles_IsItemImage] DEFAULT ((0)) NOT NULL,
    [Content]      VARBINARY (MAX) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)   CONSTRAINT [DF_ItemFiles_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]    INT             NULL,
    CONSTRAINT [PK_ItemFiles] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ItemFiles_Size] CHECK ([SizeBytes]>(0)),
    CONSTRAINT [FK_ItemFiles_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ItemFiles_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id])
);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_ItemFiles_ItemImage]
    ON [inventory].[ItemFiles]([ItemId] ASC) WHERE ([IsItemImage]=(1));


GO

CREATE NONCLUSTERED INDEX [IX_ItemFiles_Item]
    ON [inventory].[ItemFiles]([ItemId] ASC);


GO

