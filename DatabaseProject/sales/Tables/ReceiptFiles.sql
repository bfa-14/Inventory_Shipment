CREATE TABLE [sales].[ReceiptFiles] (
    [Id]               INT             IDENTITY (1, 1) NOT NULL,
    [ReceiptId]        INT             NOT NULL,
    [AttachmentTypeId] INT             NOT NULL,
    [Note]             NVARCHAR (500)  NULL,
    [FileName]         NVARCHAR (255)  NOT NULL,
    [ContentType]      NVARCHAR (100)  NOT NULL,
    [SizeBytes]        INT             NOT NULL,
    [Content]          VARBINARY (MAX) NOT NULL,
    [CreatedAtUtc]     DATETIME2 (3)   CONSTRAINT [DF_ReceiptFiles_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]        INT             NULL,
    [DocumentDate]     DATE            NULL,
    CONSTRAINT [PK_ReceiptFiles] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ReceiptFiles_Size] CHECK ([SizeBytes]>(0)),
    CONSTRAINT [FK_ReceiptFiles_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ReceiptFiles_Receipt] FOREIGN KEY ([ReceiptId]) REFERENCES [sales].[Receipts] ([Id]),
    CONSTRAINT [FK_ReceiptFiles_Type] FOREIGN KEY ([AttachmentTypeId]) REFERENCES [masterdata].[AttachmentTypes] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_ReceiptFiles_Receipt]
    ON [sales].[ReceiptFiles]([ReceiptId] ASC);


GO

