CREATE TABLE [purchase].[PurchaseDocumentFiles] (
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

ALTER TABLE [purchase].[PurchaseDocumentFiles]
    ADD CONSTRAINT [FK_PurchaseDocumentFiles_Document] FOREIGN KEY ([DocumentId]) REFERENCES [purchase].[PurchaseDocuments] ([Id]);
GO

ALTER TABLE [purchase].[PurchaseDocumentFiles]
    ADD CONSTRAINT [FK_PurchaseDocumentFiles_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]);
GO

CREATE NONCLUSTERED INDEX [IX_PurchaseDocumentFiles_Document]
    ON [purchase].[PurchaseDocumentFiles]([DocumentId] ASC);
GO

ALTER TABLE [purchase].[PurchaseDocumentFiles]
    ADD CONSTRAINT [PK_PurchaseDocumentFiles] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

ALTER TABLE [purchase].[PurchaseDocumentFiles]
    ADD CONSTRAINT [DF_PurchaseDocumentFiles_CreatedAtUtc] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];
GO

ALTER TABLE [purchase].[PurchaseDocumentFiles]
    ADD CONSTRAINT [CK_PurchaseDocumentFiles_Size] CHECK ([SizeBytes]>(0));
GO

