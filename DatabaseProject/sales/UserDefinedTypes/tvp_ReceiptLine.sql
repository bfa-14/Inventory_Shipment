CREATE TYPE [sales].[tvp_ReceiptLine] AS TABLE (
    [LineNumber]        INT             NOT NULL,
    [PaymentMethodId]   INT             NOT NULL,
    [CurrencyId]        INT             NOT NULL,
    [Amount]            DECIMAL (18, 2) NOT NULL,
    [ExchangeRate]      DECIMAL (18, 6) NULL,
    [CashBankAccountId] INT             NOT NULL,
    [Reference]         NVARCHAR (100)  NULL,
    PRIMARY KEY CLUSTERED ([LineNumber] ASC));


GO

