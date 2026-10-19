CREATE TABLE [masterdata].[UnitPrices] (
    [Id]           INT             IDENTITY (1, 1) NOT NULL,
    [BranchId]     INT             NULL,
    [ItemId]       INT             NOT NULL,
    [ItemUnitId]   INT             NOT NULL,
    [PriceListId]  INT             NOT NULL,
    [Price]        DECIMAL (18, 4) NOT NULL,
    [IsActive]     BIT             CONSTRAINT [DF_UnitPrices_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)   CONSTRAINT [DF_UnitPrices_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]    INT             NULL,
    [UpdatedAtUtc] DATETIME2 (3)   NULL,
    [UpdatedBy]    INT             NULL,
    [RowVersion]   ROWVERSION      NOT NULL,
    CONSTRAINT [PK_UnitPrices] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_UnitPrices_Price] CHECK ([Price]>=(0)),
    CONSTRAINT [FK_UnitPrices_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_UnitPrices_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_UnitPrices_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]),
    CONSTRAINT [FK_UnitPrices_ItemUnit] FOREIGN KEY ([ItemUnitId]) REFERENCES [inventory].[ItemUnits] ([Id]),
    CONSTRAINT [FK_UnitPrices_PriceList] FOREIGN KEY ([PriceListId]) REFERENCES [masterdata].[PriceLists] ([Id]),
    CONSTRAINT [FK_UnitPrices_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_UnitPrices_PriceList]
    ON [masterdata].[UnitPrices]([PriceListId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_UnitPrices_Item]
    ON [masterdata].[UnitPrices]([ItemId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_UnitPrices_Branch]
    ON [masterdata].[UnitPrices]([BranchId] ASC);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_UnitPrices_Key]
    ON [masterdata].[UnitPrices]([ItemUnitId] ASC, [PriceListId] ASC, [BranchId] ASC);


GO

