CREATE TABLE [masterdata].[PriceLists] (
    [Id]            INT            IDENTITY (1, 1) NOT NULL,
    [PriceListCode] NVARCHAR (20)  NOT NULL,
    [PriceListName] NVARCHAR (100) NOT NULL,
    [CurrencyId]    INT            NOT NULL,
    [Description]   NVARCHAR (500) NULL,
    [IsActive]      BIT            CONSTRAINT [DF_PriceLists_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc]  DATETIME2 (3)  CONSTRAINT [DF_PriceLists_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]     INT            NULL,
    [UpdatedAtUtc]  DATETIME2 (3)  NULL,
    [UpdatedBy]     INT            NULL,
    [RowVersion]    ROWVERSION     NOT NULL,
    CONSTRAINT [PK_PriceLists] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_PriceLists_Code_NotBlank] CHECK (len(ltrim(rtrim([PriceListCode])))>(0)),
    CONSTRAINT [CK_PriceLists_Name_NotBlank] CHECK (len(ltrim(rtrim([PriceListName])))>(0)),
    CONSTRAINT [FK_PriceLists_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_PriceLists_Currency] FOREIGN KEY ([CurrencyId]) REFERENCES [masterdata].[Currencies] ([Id]),
    CONSTRAINT [FK_PriceLists_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_PriceLists_Code] UNIQUE NONCLUSTERED ([PriceListCode] ASC),
    CONSTRAINT [UQ_PriceLists_Name] UNIQUE NONCLUSTERED ([PriceListName] ASC)
);

