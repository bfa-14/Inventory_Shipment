CREATE TABLE [inventory].[Items] (
    [Id]                 INT             IDENTITY (1, 1) NOT NULL,
    [ItemCode]           NVARCHAR (30)   NOT NULL,
    [ItemName]           NVARCHAR (200)  NOT NULL,
    [BrandId]            INT             NOT NULL,
    [Model]              NVARCHAR (100)  NULL,
    [ItemFamilyId]       INT             NOT NULL,
    [CountryOfOrigin]    NVARCHAR (2)    NOT NULL,
    [DefaultWarehouseId] INT             NOT NULL,
    [Description]        NVARCHAR (1000) NULL,
    [WarrantyMonths]     INT             NULL,
    [MinQuantity]        INT             CONSTRAINT [DF_Items_MinQuantity] DEFAULT ((0)) NOT NULL,
    [MaxQuantity]        INT             NULL,
    [IsBivac]            BIT             CONSTRAINT [DF_Items_IsBivac] DEFAULT ((0)) NOT NULL,
    [IsActive]           BIT             CONSTRAINT [DF_Items_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc]       DATETIME2 (3)   CONSTRAINT [DF_Items_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]          INT             NULL,
    [UpdatedAtUtc]       DATETIME2 (3)   NULL,
    [UpdatedBy]          INT             NULL,
    [RowVersion]         ROWVERSION      NOT NULL,
    [AverageCost]        DECIMAL (18, 6) CONSTRAINT [DF_Items_AverageCost] DEFAULT ((0)) NOT NULL,
    [LastCost]           DECIMAL (18, 6) NULL,
    [LastSupplierId]     INT             NULL,
    [LastPurchaseAtUtc]  DATETIME2 (3)   NULL,
    [DefaultSupplierId]  INT             NULL,
    [LeadTimeDays]       INT             NULL,
    CONSTRAINT [PK_Items] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_Items_ItemCode_NotBlank] CHECK (len(ltrim(rtrim([ItemCode])))>(0)),
    CONSTRAINT [CK_Items_ItemName_NotBlank] CHECK (len(ltrim(rtrim([ItemName])))>(0)),
    CONSTRAINT [CK_Items_LeadTime] CHECK ([LeadTimeDays] IS NULL OR [LeadTimeDays]>=(0)),
    CONSTRAINT [CK_Items_MaxQuantity] CHECK ([MaxQuantity] IS NULL OR [MaxQuantity]>=(0)),
    CONSTRAINT [CK_Items_MinMax] CHECK ([MaxQuantity] IS NULL OR [MinQuantity]<=[MaxQuantity]),
    CONSTRAINT [CK_Items_MinQuantity] CHECK ([MinQuantity]>=(0)),
    CONSTRAINT [CK_Items_Warranty] CHECK ([WarrantyMonths] IS NULL OR [WarrantyMonths]>=(0)),
    CONSTRAINT [FK_Items_Brand] FOREIGN KEY ([BrandId]) REFERENCES [masterdata].[Brands] ([Id]),
    CONSTRAINT [FK_Items_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Items_DefaultSupplier] FOREIGN KEY ([DefaultSupplierId]) REFERENCES [masterdata].[Parties] ([Id]),
    CONSTRAINT [FK_Items_Family] FOREIGN KEY ([ItemFamilyId]) REFERENCES [masterdata].[ItemFamilies] ([Id]),
    CONSTRAINT [FK_Items_LastSupplier] FOREIGN KEY ([LastSupplierId]) REFERENCES [masterdata].[Parties] ([Id]),
    CONSTRAINT [FK_Items_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Items_Warehouse] FOREIGN KEY ([DefaultWarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]),
    CONSTRAINT [UQ_Items_ItemCode] UNIQUE NONCLUSTERED ([ItemCode] ASC)
);




GO
CREATE NONCLUSTERED INDEX [IX_Items_Warehouse]
    ON [inventory].[Items]([DefaultWarehouseId] ASC);


GO
CREATE NONCLUSTERED INDEX [IX_Items_Brand]
    ON [inventory].[Items]([BrandId] ASC);


GO
CREATE NONCLUSTERED INDEX [IX_Items_Family]
    ON [inventory].[Items]([ItemFamilyId] ASC);


GO
CREATE NONCLUSTERED INDEX [IX_Items_ItemName]
    ON [inventory].[Items]([ItemName] ASC);

