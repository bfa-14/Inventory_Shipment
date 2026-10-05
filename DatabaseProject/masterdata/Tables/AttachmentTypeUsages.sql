CREATE TABLE [masterdata].[AttachmentTypeUsages] (
    [AttachmentTypeId] INT           NOT NULL,
    [DocumentKind]     NVARCHAR (20) NOT NULL,
    CONSTRAINT [PK_AttachmentTypeUsages] PRIMARY KEY CLUSTERED ([AttachmentTypeId] ASC, [DocumentKind] ASC),
    CONSTRAINT [FK_AttachmentTypeUsages_Type] FOREIGN KEY ([AttachmentTypeId]) REFERENCES [masterdata].[AttachmentTypes] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_AttachmentTypeUsages_Kind]
    ON [masterdata].[AttachmentTypeUsages]([DocumentKind] ASC);


GO

