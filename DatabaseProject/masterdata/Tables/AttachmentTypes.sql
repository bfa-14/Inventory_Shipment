CREATE TABLE [masterdata].[AttachmentTypes] (
    [Id]           INT           IDENTITY (1, 1) NOT NULL,
    [Category]     NVARCHAR (30) NOT NULL,
    [SubType]      NVARCHAR (60) NOT NULL,
    [IsActive]     BIT           NOT NULL,
    [SortOrder]    INT           NOT NULL,
    [CreatedAtUtc] DATETIME2 (3) NOT NULL,
    [CreatedBy]    INT           NULL,
    [UpdatedAtUtc] DATETIME2 (3) NULL,
    [UpdatedBy]    INT           NULL,
    [RowVersion]   ROWVERSION    NOT NULL
);
GO

ALTER TABLE [masterdata].[AttachmentTypes]
    ADD CONSTRAINT [FK_AttachmentTypes_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [masterdata].[AttachmentTypes]
    ADD CONSTRAINT [FK_AttachmentTypes_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]);
GO

ALTER TABLE [masterdata].[AttachmentTypes]
    ADD CONSTRAINT [DF_AttachmentTypes_SortOrder] DEFAULT ((0)) FOR [SortOrder];
GO

ALTER TABLE [masterdata].[AttachmentTypes]
    ADD CONSTRAINT [DF_AttachmentTypes_IsActive] DEFAULT ((1)) FOR [IsActive];
GO

ALTER TABLE [masterdata].[AttachmentTypes]
    ADD CONSTRAINT [DF_AttachmentTypes_CreatedAtUtc] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];
GO

ALTER TABLE [masterdata].[AttachmentTypes]
    ADD CONSTRAINT [UQ_AttachmentTypes_Name] UNIQUE NONCLUSTERED ([Category] ASC, [SubType] ASC);
GO

ALTER TABLE [masterdata].[AttachmentTypes]
    ADD CONSTRAINT [PK_AttachmentTypes] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

