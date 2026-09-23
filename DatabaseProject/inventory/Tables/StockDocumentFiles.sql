CREATE TABLE [inventory].[StockDocumentFiles] (
    [Id]           INT             IDENTITY (1, 1) NOT NULL,
    [DocumentId]   INT             NOT NULL,
    [FileName]     NVARCHAR (255)  NOT NULL,
    [ContentType]  NVARCHAR (100)  NOT NULL,
    [SizeBytes]    INT             NOT NULL,
    [Content]      VARBINARY (MAX) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)   NOT NULL,
    [CreatedBy]    INT             NULL
);
GO

ALTER TABLE [inventory].[StockDocumentFiles]
    ADD CONSTRAINT [FK_StockDocumentFiles_Document] FOREIGN KEY ([DocumentId]) REFERENCES [inventory].[StockDocuments] ([Id]);
GO

ALTER TABLE [inventory].[StockDocumentFiles]
    ADD CONSTRAINT [FK_StockDocumentFiles_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [inventory].[StockDocumentFiles]
    ADD CONSTRAINT [CK_StockDocumentFiles_Size] CHECK ([SizeBytes]>(0));
GO

CREATE NONCLUSTERED INDEX [IX_StockDocumentFiles_Document]
    ON [inventory].[StockDocumentFiles]([DocumentId] ASC);
GO

ALTER TABLE [inventory].[StockDocumentFiles]
    ADD CONSTRAINT [DF_StockDocumentFiles_CreatedAtUtc] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];
GO

ALTER TABLE [inventory].[StockDocumentFiles]
    ADD CONSTRAINT [PK_StockDocumentFiles] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

