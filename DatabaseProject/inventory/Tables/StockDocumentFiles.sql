CREATE TABLE [inventory].[StockDocumentFiles] (
    [Id]               INT             IDENTITY (1, 1) NOT NULL,
    [DocumentId]       INT             NOT NULL,
    [FileName]         NVARCHAR (255)  NOT NULL,
    [ContentType]      NVARCHAR (100)  NOT NULL,
    [SizeBytes]        INT             NOT NULL,
    [Content]          VARBINARY (MAX) NOT NULL,
    [CreatedAtUtc]     DATETIME2 (3)   CONSTRAINT [DF_StockDocumentFiles_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]        INT             NULL,
    [AttachmentTypeId] INT             NOT NULL,
    [DocumentDate]     DATE            NULL,
    [Note]             NVARCHAR (500)  NULL,
    CONSTRAINT [PK_StockDocumentFiles] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_StockDocumentFiles_Size] CHECK ([SizeBytes]>(0)),
    CONSTRAINT [FK_StockDocumentFiles_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_StockDocumentFiles_Document] FOREIGN KEY ([DocumentId]) REFERENCES [inventory].[StockDocuments] ([Id]),
    CONSTRAINT [FK_StockDocumentFiles_Type] FOREIGN KEY ([AttachmentTypeId]) REFERENCES [masterdata].[AttachmentTypes] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_StockDocumentFiles_Document]
    ON [inventory].[StockDocumentFiles]([DocumentId] ASC);


GO

