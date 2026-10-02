CREATE TABLE [masterdata].[Currencies] (
    [Id]             INT            IDENTITY (1, 1) NOT NULL,
    [CurrencyCode]   NVARCHAR (3)   NOT NULL,
    [CurrencyName]   NVARCHAR (100) NOT NULL,
    [Symbol]         NVARCHAR (10)  NULL,
    [DecimalPlaces]  TINYINT        CONSTRAINT [DF_Currencies_DecimalPlaces] DEFAULT ((2)) NOT NULL,
    [IsBaseCurrency] BIT            CONSTRAINT [DF_Currencies_IsBaseCurrency] DEFAULT ((0)) NOT NULL,
    [IsActive]       BIT            CONSTRAINT [DF_Currencies_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc]   DATETIME2 (3)  CONSTRAINT [DF_Currencies_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]      INT            NULL,
    [UpdatedAtUtc]   DATETIME2 (3)  NULL,
    [UpdatedBy]      INT            NULL,
    [RowVersion]     ROWVERSION     NOT NULL,
    CONSTRAINT [PK_Currencies] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_Currencies_BaseIsActive] CHECK ([IsBaseCurrency]=(0) OR [IsActive]=(1)),
    CONSTRAINT [CK_Currencies_CurrencyCode_NotBlank] CHECK (len(ltrim(rtrim([CurrencyCode])))>(0)),
    CONSTRAINT [CK_Currencies_CurrencyName_NotBlank] CHECK (len(ltrim(rtrim([CurrencyName])))>(0)),
    CONSTRAINT [CK_Currencies_DecimalPlaces] CHECK ([DecimalPlaces]<=(6)),
    CONSTRAINT [FK_Currencies_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Currencies_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_Currencies_CurrencyCode] UNIQUE NONCLUSTERED ([CurrencyCode] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_Currencies_CurrencyName]
    ON [masterdata].[Currencies]([CurrencyName] ASC);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_Currencies_ActiveBaseCurrency]
    ON [masterdata].[Currencies]([IsBaseCurrency] ASC) WHERE ([IsBaseCurrency]=(1) AND [IsActive]=(1));


GO

