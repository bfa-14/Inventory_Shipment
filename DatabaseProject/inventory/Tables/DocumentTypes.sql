CREATE TABLE [inventory].[DocumentTypes] (
    [Id]             INT            IDENTITY (1, 1) NOT NULL,
    [Code]           NVARCHAR (20)  NOT NULL,
    [Name]           NVARCHAR (100) NOT NULL,
    [Family]         NVARCHAR (20)  NOT NULL,
    [StockDirection] SMALLINT       NOT NULL,
    [NumberPrefix]   NVARCHAR (10)  NOT NULL,
    [NextNumber]     INT            CONSTRAINT [DF_DocumentTypes_NextNumber] DEFAULT ((1)) NOT NULL,
    [NumberLength]   TINYINT        CONSTRAINT [DF_DocumentTypes_NumberLength] DEFAULT ((6)) NOT NULL,
    [NumberOnPost]   BIT            CONSTRAINT [DF_DocumentTypes_NumberOnPost] DEFAULT ((0)) NOT NULL,
    [RequiresReason] BIT            CONSTRAINT [DF_DocumentTypes_RequiresReason] DEFAULT ((0)) NOT NULL,
    [IsActive]       BIT            CONSTRAINT [DF_DocumentTypes_IsActive] DEFAULT ((1)) NOT NULL,
    [UpdatedAtUtc]   DATETIME2 (3)  NULL,
    [UpdatedBy]      INT            NULL,
    [RowVersion]     ROWVERSION     NOT NULL,
    CONSTRAINT [PK_DocumentTypes] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_DocumentTypes_Direction] CHECK ([StockDirection]=(1) OR [StockDirection]=(0) OR [StockDirection]=(-1)),
    CONSTRAINT [CK_DocumentTypes_Family] CHECK ([Family]=N'Sales' OR [Family]=N'Purchase' OR [Family]=N'Inventory'),
    CONSTRAINT [CK_DocumentTypes_NumberLength] CHECK ([NumberLength]>=(3) AND [NumberLength]<=(10)),
    CONSTRAINT [UQ_DocumentTypes_Code] UNIQUE NONCLUSTERED ([Code] ASC)
);

