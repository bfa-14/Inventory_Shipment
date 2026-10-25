CREATE TABLE [inventory].[TransferOrderFiles] (
    [Id]               INT             IDENTITY (1, 1) NOT NULL,
    [TransferOrderId]  INT             NOT NULL,
    [AttachmentTypeId] INT             NOT NULL,
    [DocumentDate]     DATE            NULL,
    [Note]             NVARCHAR (500)  NULL,
    [FileName]         NVARCHAR (255)  NOT NULL,
    [ContentType]      NVARCHAR (100)  NOT NULL,
    [SizeBytes]        INT             NOT NULL,
    [Content]          VARBINARY (MAX) NOT NULL,
    [CreatedAtUtc]     DATETIME2 (3)   CONSTRAINT [DF_TransferOrderFiles_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]        INT             NULL,
    CONSTRAINT [PK_TransferOrderFiles] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_TransferOrderFiles_Size] CHECK ([SizeBytes]>(0)),
    CONSTRAINT [FK_TransferOrderFiles_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_TransferOrderFiles_Order] FOREIGN KEY ([TransferOrderId]) REFERENCES [inventory].[TransferOrders] ([Id]),
    CONSTRAINT [FK_TransferOrderFiles_Type] FOREIGN KEY ([AttachmentTypeId]) REFERENCES [masterdata].[AttachmentTypes] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_TransferOrderFiles_Order]
    ON [inventory].[TransferOrderFiles]([TransferOrderId] ASC);


GO

