CREATE TYPE [purchase].[tvp_PaymentLine] AS TABLE (
    [LineNumber]        INT              NOT NULL,
    [PaymentMethodId]   INT              NOT NULL,
    [CurrencyId]        INT              NOT NULL,
    [Amount]            DECIMAL (18, 2)  NOT NULL,
    [RateToPayment]     DECIMAL (24, 12) NULL,
    [CashBankAccountId] INT              NOT NULL,
    [Reference]         NVARCHAR (100)   NULL,
    [ChequeNo]          NVARCHAR (50)    NULL,
    [ChequeDate]        DATE             NULL,
    [ChequeDueDate]     DATE             NULL,
    PRIMARY KEY CLUSTERED ([LineNumber] ASC));


GO

