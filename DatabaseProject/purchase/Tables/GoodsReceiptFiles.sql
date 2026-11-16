CREATE TABLE [purchase].[GoodsReceiptFiles] (
    [Id]               INT             IDENTITY (1, 1) NOT NULL,
    [GoodsReceiptId]   INT             NOT NULL,
    [AttachmentTypeId] INT             NOT NULL,
    [DocumentDate]     DATE            NULL,
    [Note]             NVARCHAR (500)  NULL,
    [FileName]         NVARCHAR (255)  NOT NULL,
    [ContentType]      NVARCHAR (100)  NOT NULL,
    [SizeBytes]        INT             NOT NULL,
    [Content]          VARBINARY (MAX) NOT NULL,
    [CreatedAtUtc]     DATETIME2 (3)   CONSTRAINT [DF_GoodsReceiptFiles_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]        INT             NULL,
    CONSTRAINT [PK_GoodsReceiptFiles] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_GoodsReceiptFiles_Size] CHECK ([SizeBytes]>(0)),
    CONSTRAINT [FK_GoodsReceiptFiles_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_GoodsReceiptFiles_Receipt] FOREIGN KEY ([GoodsReceiptId]) REFERENCES [purchase].[GoodsReceipts] ([Id]),
    CONSTRAINT [FK_GoodsReceiptFiles_Type] FOREIGN KEY ([AttachmentTypeId]) REFERENCES [masterdata].[AttachmentTypes] ([Id])
);




GO

CREATE NONCLUSTERED INDEX [IX_GoodsReceiptFiles_Receipt]
    ON [purchase].[GoodsReceiptFiles]([GoodsReceiptId] ASC);


GO
CREATE NONCLUSTERED INDEX [IX_GoodsReceiptFiles_Report]
    ON [purchase].[GoodsReceiptFiles]([DocumentDate] ASC, [CreatedAtUtc] ASC)
    INCLUDE([GoodsReceiptId], [AttachmentTypeId], [FileName], [ContentType], [SizeBytes], [CreatedBy]);

