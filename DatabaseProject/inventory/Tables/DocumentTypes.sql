CREATE TABLE [inventory].[DocumentTypes] (
    [Id]              INT            IDENTITY (1, 1) NOT NULL,
    [Code]            NVARCHAR (20)  NOT NULL,
    [Name]            NVARCHAR (100) NOT NULL,
    [Family]          NVARCHAR (20)  NOT NULL,
    [StockDirection]  SMALLINT       NOT NULL,
    [NumberPrefix]    NVARCHAR (10)  NOT NULL,
    [NextNumber]      INT            NOT NULL,
    [NumberLength]    TINYINT        NOT NULL,
    [NumberOnPost]    BIT            NOT NULL,
    [RequiresReason]  BIT            NOT NULL,
    [IsActive]        BIT            NOT NULL,
    [UpdatedAtUtc]    DATETIME2 (3)  NULL,
    [UpdatedBy]       INT            NULL,
    [RowVersion]      ROWVERSION     NOT NULL,
    [DefaultPricing]  NVARCHAR (10)  NOT NULL,
    [PriceEditable]   BIT            NOT NULL,
    [NumberPerBranch] BIT            NOT NULL,
    [YearInNumber]    BIT            NOT NULL,
    [NextNumberYear]  INT            NULL
);
GO

ALTER TABLE [inventory].[DocumentTypes]
    ADD CONSTRAINT [CK_DocumentTypes_Family] CHECK ([Family]=N'Logistics' OR [Family]=N'Sales' OR [Family]=N'Purchase' OR [Family]=N'Inventory');
GO

ALTER TABLE [inventory].[DocumentTypes]
    ADD CONSTRAINT [CK_DocumentTypes_DefaultPricing] CHECK ([DefaultPricing]=N'None' OR [DefaultPricing]=N'PriceList' OR [DefaultPricing]=N'Cost');
GO

ALTER TABLE [inventory].[DocumentTypes]
    ADD CONSTRAINT [CK_DocumentTypes_NumberLength] CHECK ([NumberLength]>=(3) AND [NumberLength]<=(10));
GO

ALTER TABLE [inventory].[DocumentTypes]
    ADD CONSTRAINT [CK_DocumentTypes_Direction] CHECK ([StockDirection]=(1) OR [StockDirection]=(0) OR [StockDirection]=(-1));
GO

ALTER TABLE [inventory].[DocumentTypes]
    ADD CONSTRAINT [DF_DocumentTypes_IsActive] DEFAULT ((1)) FOR [IsActive];
GO

ALTER TABLE [inventory].[DocumentTypes]
    ADD CONSTRAINT [DF_DocumentTypes_NumberPerBranch] DEFAULT ((1)) FOR [NumberPerBranch];
GO

ALTER TABLE [inventory].[DocumentTypes]
    ADD CONSTRAINT [DF_DocumentTypes_PriceEditable] DEFAULT ((1)) FOR [PriceEditable];
GO

ALTER TABLE [inventory].[DocumentTypes]
    ADD CONSTRAINT [DF_DocumentTypes_DefaultPricing] DEFAULT (N'Cost') FOR [DefaultPricing];
GO

ALTER TABLE [inventory].[DocumentTypes]
    ADD CONSTRAINT [DF_DocumentTypes_NumberOnPost] DEFAULT ((0)) FOR [NumberOnPost];
GO

ALTER TABLE [inventory].[DocumentTypes]
    ADD CONSTRAINT [DF_DocumentTypes_RequiresReason] DEFAULT ((0)) FOR [RequiresReason];
GO

ALTER TABLE [inventory].[DocumentTypes]
    ADD CONSTRAINT [DF_DocumentTypes_NextNumber] DEFAULT ((1)) FOR [NextNumber];
GO

ALTER TABLE [inventory].[DocumentTypes]
    ADD CONSTRAINT [DF_DocumentTypes_NumberLength] DEFAULT ((6)) FOR [NumberLength];
GO

ALTER TABLE [inventory].[DocumentTypes]
    ADD CONSTRAINT [DF_DocumentTypes_YearInNumber] DEFAULT ((0)) FOR [YearInNumber];
GO

ALTER TABLE [inventory].[DocumentTypes]
    ADD CONSTRAINT [UQ_DocumentTypes_Code] UNIQUE NONCLUSTERED ([Code] ASC);
GO

ALTER TABLE [inventory].[DocumentTypes]
    ADD CONSTRAINT [PK_DocumentTypes] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

