CREATE TABLE [inventory].[ItemUnits] (
    [Id]             INT           IDENTITY (1, 1) NOT NULL,
    [ItemId]         INT           NOT NULL,
    [UnitTypeId]     INT           NOT NULL,
    [PackingFormula] INT           NOT NULL,
    [SkuCode]        NVARCHAR (50) NOT NULL,
    [Barcode]        NVARCHAR (50) NULL,
    [IsSalesUnit]    BIT           CONSTRAINT [DF_ItemUnits_IsSalesUnit] DEFAULT ((0)) NOT NULL,
    [IsPurchaseUnit] BIT           CONSTRAINT [DF_ItemUnits_IsPurchaseUnit] DEFAULT ((0)) NOT NULL,
    [IsBaseUnit]     BIT           CONSTRAINT [DF_ItemUnits_IsBaseUnit] DEFAULT ((0)) NOT NULL,
    [CreatedAtUtc]   DATETIME2 (3) CONSTRAINT [DF_ItemUnits_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]      INT           NULL,
    [UpdatedAtUtc]   DATETIME2 (3) NULL,
    [UpdatedBy]      INT           NULL,
    [RowVersion]     ROWVERSION    NOT NULL,
    CONSTRAINT [PK_ItemUnits] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ItemUnits_BaseFormula] CHECK ([IsBaseUnit]=(0) OR [PackingFormula]=(1)),
    CONSTRAINT [CK_ItemUnits_Formula] CHECK ([PackingFormula]>=(1)),
    CONSTRAINT [CK_ItemUnits_Sku_NotBlank] CHECK (len(ltrim(rtrim([SkuCode])))>(0)),
    CONSTRAINT [FK_ItemUnits_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ItemUnits_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]),
    CONSTRAINT [FK_ItemUnits_UnitType] FOREIGN KEY ([UnitTypeId]) REFERENCES [masterdata].[UnitTypes] ([Id]),
    CONSTRAINT [FK_ItemUnits_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_ItemUnits_Item_Sku] UNIQUE NONCLUSTERED ([ItemId] ASC, [SkuCode] ASC),
    CONSTRAINT [UQ_ItemUnits_Item_UnitType] UNIQUE NONCLUSTERED ([ItemId] ASC, [UnitTypeId] ASC)
);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_ItemUnits_BaseUnit]
    ON [inventory].[ItemUnits]([ItemId] ASC) WHERE ([IsBaseUnit]=(1));


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_ItemUnits_Barcode]
    ON [inventory].[ItemUnits]([Barcode] ASC) WHERE ([Barcode] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_ItemUnits_Item]
    ON [inventory].[ItemUnits]([ItemId] ASC);


GO

