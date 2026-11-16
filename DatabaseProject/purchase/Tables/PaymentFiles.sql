CREATE TABLE [purchase].[PaymentFiles] (
    [Id]               INT             IDENTITY (1, 1) NOT NULL,
    [PaymentId]        INT             NOT NULL,
    [AttachmentTypeId] INT             NOT NULL,
    [Note]             NVARCHAR (500)  NULL,
    [FileName]         NVARCHAR (255)  NOT NULL,
    [ContentType]      NVARCHAR (100)  NOT NULL,
    [SizeBytes]        INT             NOT NULL,
    [Content]          VARBINARY (MAX) NOT NULL,
    [CreatedAtUtc]     DATETIME2 (3)   CONSTRAINT [DF_PaymentFiles_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]        INT             NULL,
    [DocumentDate]     DATE            NULL,
    CONSTRAINT [PK_PaymentFiles] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_PaymentFiles_Size] CHECK ([SizeBytes]>(0)),
    CONSTRAINT [FK_PaymentFiles_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_PaymentFiles_Payment] FOREIGN KEY ([PaymentId]) REFERENCES [purchase].[Payments] ([Id]),
    CONSTRAINT [FK_PaymentFiles_Type] FOREIGN KEY ([AttachmentTypeId]) REFERENCES [masterdata].[AttachmentTypes] ([Id])
);




GO

CREATE NONCLUSTERED INDEX [IX_PaymentFiles_Payment]
    ON [purchase].[PaymentFiles]([PaymentId] ASC);


GO
CREATE NONCLUSTERED INDEX [IX_PaymentFiles_Report]
    ON [purchase].[PaymentFiles]([DocumentDate] ASC, [CreatedAtUtc] ASC)
    INCLUDE([PaymentId], [AttachmentTypeId], [FileName], [ContentType], [SizeBytes], [CreatedBy]);

