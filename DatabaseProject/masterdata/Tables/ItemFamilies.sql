CREATE TABLE [masterdata].[ItemFamilies] (
    [Id]           INT            IDENTITY (1, 1) NOT NULL,
    [ParentId]     INT            NULL,
    [FamilyCode]   NVARCHAR (50)  NOT NULL,
    [FamilyName]   NVARCHAR (150) NOT NULL,
    [Description]  NVARCHAR (500) NULL,
    [Level]        INT            CONSTRAINT [DF_ItemFamilies_Level] DEFAULT ((1)) NOT NULL,
    [IsActive]     BIT            CONSTRAINT [DF_ItemFamilies_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)  CONSTRAINT [DF_ItemFamilies_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]    INT            NULL,
    [UpdatedAtUtc] DATETIME2 (3)  NULL,
    [UpdatedBy]    INT            NULL,
    [RowVersion]   ROWVERSION     NOT NULL,
    CONSTRAINT [PK_ItemFamilies] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ItemFamilies_FamilyCode_NotBlank] CHECK (len(ltrim(rtrim([FamilyCode])))>(0)),
    CONSTRAINT [CK_ItemFamilies_FamilyName_NotBlank] CHECK (len(ltrim(rtrim([FamilyName])))>(0)),
    CONSTRAINT [CK_ItemFamilies_Level] CHECK ([Level]>=(1)),
    CONSTRAINT [CK_ItemFamilies_NotOwnParent] CHECK ([ParentId] IS NULL OR [ParentId]<>[Id]),
    CONSTRAINT [FK_ItemFamilies_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ItemFamilies_Parent] FOREIGN KEY ([ParentId]) REFERENCES [masterdata].[ItemFamilies] ([Id]),
    CONSTRAINT [FK_ItemFamilies_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_ItemFamilies_FamilyCode] UNIQUE NONCLUSTERED ([FamilyCode] ASC)
);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_ItemFamilies_Parent_FamilyName]
    ON [masterdata].[ItemFamilies]([ParentId] ASC, [FamilyName] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_ItemFamilies_ParentId]
    ON [masterdata].[ItemFamilies]([ParentId] ASC);


GO

