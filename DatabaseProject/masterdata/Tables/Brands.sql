CREATE TABLE [masterdata].[Brands] (
    [Id]           INT            IDENTITY (1, 1) NOT NULL,
    [BrandCode]    NVARCHAR (20)  NOT NULL,
    [BrandName]    NVARCHAR (150) NOT NULL,
    [Description]  NVARCHAR (500) NULL,
    [IsActive]     BIT            CONSTRAINT [DF_Brands_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)  CONSTRAINT [DF_Brands_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]    INT            NULL,
    [UpdatedAtUtc] DATETIME2 (3)  NULL,
    [UpdatedBy]    INT            NULL,
    [RowVersion]   ROWVERSION     NOT NULL,
    CONSTRAINT [PK_Brands] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_Brands_BrandCode_NotBlank] CHECK (len(ltrim(rtrim([BrandCode])))>(0)),
    CONSTRAINT [CK_Brands_BrandName_NotBlank] CHECK (len(ltrim(rtrim([BrandName])))>(0)),
    CONSTRAINT [FK_Brands_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Brands_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_Brands_BrandCode] UNIQUE NONCLUSTERED ([BrandCode] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_Brands_BrandName]
    ON [masterdata].[Brands]([BrandName] ASC);


GO

