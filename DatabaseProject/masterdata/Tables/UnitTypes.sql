CREATE TABLE [masterdata].[UnitTypes] (
    [Id]           INT           IDENTITY (1, 1) NOT NULL,
    [UnitTypeName] NVARCHAR (50) NOT NULL,
    [IsActive]     BIT           CONSTRAINT [DF_UnitTypes_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3) CONSTRAINT [DF_UnitTypes_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]    INT           NULL,
    [UpdatedAtUtc] DATETIME2 (3) NULL,
    [UpdatedBy]    INT           NULL,
    [RowVersion]   ROWVERSION    NOT NULL,
    [IsContainer]  BIT           CONSTRAINT [DF_UnitTypes_IsContainer] DEFAULT ((0)) NOT NULL,
    CONSTRAINT [PK_UnitTypes] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_UnitTypes_Name_NotBlank] CHECK (len(ltrim(rtrim([UnitTypeName])))>(0)),
    CONSTRAINT [FK_UnitTypes_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_UnitTypes_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_UnitTypes_UnitTypeName] UNIQUE NONCLUSTERED ([UnitTypeName] ASC)
);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_UnitTypes_Container]
    ON [masterdata].[UnitTypes]([IsContainer] ASC) WHERE ([IsContainer]=(1));


GO

