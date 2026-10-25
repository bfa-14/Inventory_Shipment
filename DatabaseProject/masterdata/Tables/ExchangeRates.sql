CREATE TABLE [masterdata].[ExchangeRates] (
    [Id]           INT             IDENTITY (1, 1) NOT NULL,
    [CurrencyId]   INT             NOT NULL,
    [RateType]     TINYINT         NOT NULL,
    [RateDate]     DATE            NOT NULL,
    [Rate]         DECIMAL (18, 6) NOT NULL,
    [Notes]        NVARCHAR (300)  NULL,
    [CreatedAtUtc] DATETIME2 (3)   CONSTRAINT [DF_ExchangeRates_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]    INT             NULL,
    [UpdatedAtUtc] DATETIME2 (3)   NULL,
    [UpdatedBy]    INT             NULL,
    [RowVersion]   ROWVERSION      NOT NULL,
    CONSTRAINT [PK_ExchangeRates] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ExchangeRates_Rate] CHECK ([Rate]>(0)),
    CONSTRAINT [CK_ExchangeRates_RateType] CHECK ([RateType]=(3) OR [RateType]=(2) OR [RateType]=(1)),
    CONSTRAINT [FK_ExchangeRates_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_ExchangeRates_Currency] FOREIGN KEY ([CurrencyId]) REFERENCES [masterdata].[Currencies] ([Id]),
    CONSTRAINT [FK_ExchangeRates_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_ExchangeRates_Currency_Type_Date]
    ON [masterdata].[ExchangeRates]([CurrencyId] ASC, [RateType] ASC, [RateDate] DESC)
    INCLUDE([Rate]);


GO

CREATE NONCLUSTERED INDEX [IX_ExchangeRates_RateDate]
    ON [masterdata].[ExchangeRates]([RateDate] ASC);


GO

