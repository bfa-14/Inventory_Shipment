CREATE TABLE [sales].[ReceiptLines] (
    [Id]                INT             IDENTITY (1, 1) NOT NULL,
    [ReceiptId]         INT             NOT NULL,
    [LineNumber]        INT             NOT NULL,
    [PaymentMethodId]   INT             NOT NULL,
    [CurrencyId]        INT             NOT NULL,
    [Amount]            DECIMAL (18, 2) NOT NULL,
    [ExchangeRate]      DECIMAL (18, 6) CONSTRAINT [DF_ReceiptLines_Rate] DEFAULT ((1)) NOT NULL,
    [AmountBase]        AS              (CONVERT([decimal](18,2),[Amount]/[ExchangeRate])) PERSISTED,
    [CashBankAccountId] INT             NOT NULL,
    [Reference]         NVARCHAR (100)  NULL,
    CONSTRAINT [PK_ReceiptLines] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ReceiptLines_Amount] CHECK ([Amount]>(0)),
    CONSTRAINT [CK_ReceiptLines_Rate] CHECK ([ExchangeRate]>(0)),
    CONSTRAINT [FK_ReceiptLines_Account] FOREIGN KEY ([CashBankAccountId]) REFERENCES [masterdata].[CashBankAccounts] ([Id]),
    CONSTRAINT [FK_ReceiptLines_Currency] FOREIGN KEY ([CurrencyId]) REFERENCES [masterdata].[Currencies] ([Id]),
    CONSTRAINT [FK_ReceiptLines_Method] FOREIGN KEY ([PaymentMethodId]) REFERENCES [masterdata].[PaymentMethods] ([Id]),
    CONSTRAINT [FK_ReceiptLines_Receipt] FOREIGN KEY ([ReceiptId]) REFERENCES [sales].[Receipts] ([Id]),
    CONSTRAINT [UQ_ReceiptLines_Number] UNIQUE NONCLUSTERED ([ReceiptId] ASC, [LineNumber] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_ReceiptLines_Account]
    ON [sales].[ReceiptLines]([CashBankAccountId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_ReceiptLines_Method]
    ON [sales].[ReceiptLines]([PaymentMethodId] ASC);


GO

