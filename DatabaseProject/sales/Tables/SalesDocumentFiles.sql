CREATE TABLE [sales].[SalesDocumentFiles] (
    [Id]           INT             IDENTITY (1, 1) NOT NULL,
    [DocumentId]   INT             NOT NULL,
    [FileName]     NVARCHAR (255)  NOT NULL,
    [ContentType]  NVARCHAR (100)  NOT NULL,
    [SizeBytes]    INT             NOT NULL,
    [Content]      VARBINARY (MAX) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)   CONSTRAINT [DF_SalesDocumentFiles_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]    INT             NULL,
    CONSTRAINT [PK_SalesDocumentFiles] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_SalesDocumentFiles_Size] CHECK ([SizeBytes]>(0)),
    CONSTRAINT [FK_SalesDocumentFiles_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_SalesDocumentFiles_Document] FOREIGN KEY ([DocumentId]) REFERENCES [sales].[SalesDocuments] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_SalesDocumentFiles_Document]
    ON [sales].[SalesDocumentFiles]([DocumentId] ASC);


GO

