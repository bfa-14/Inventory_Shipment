CREATE TABLE [masterdata].[AttachmentTypes] (
    [Id]           INT           IDENTITY (1, 1) NOT NULL,
    [Category]     NVARCHAR (30) NOT NULL,
    [SubType]      NVARCHAR (60) NOT NULL,
    [IsActive]     BIT           CONSTRAINT [DF_AttachmentTypes_IsActive] DEFAULT ((1)) NOT NULL,
    [SortOrder]    INT           CONSTRAINT [DF_AttachmentTypes_SortOrder] DEFAULT ((0)) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3) CONSTRAINT [DF_AttachmentTypes_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]    INT           NULL,
    [UpdatedAtUtc] DATETIME2 (3) NULL,
    [UpdatedBy]    INT           NULL,
    [RowVersion]   ROWVERSION    NOT NULL,
    [AppliesTo]    NVARCHAR (12) CONSTRAINT [DF_AttachmentTypes_AppliesTo] DEFAULT (N'Logistics') NOT NULL,
    CONSTRAINT [PK_AttachmentTypes] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_AttachmentTypes_AppliesTo] CHECK ([AppliesTo]=N'Receipt' OR [AppliesTo]=N'Logistics'),
    CONSTRAINT [FK_AttachmentTypes_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_AttachmentTypes_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_AttachmentTypes_Name] UNIQUE NONCLUSTERED ([Category] ASC, [SubType] ASC)
);


GO

