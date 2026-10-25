CREATE TABLE [purchase].[PaymentLines] (
    [Id]                    INT              IDENTITY (1, 1) NOT NULL,
    [PaymentId]             INT              NOT NULL,
    [LineNumber]            INT              NOT NULL,
    [PaymentMethodId]       INT              NOT NULL,
    [CurrencyId]            INT              NOT NULL,
    [Amount]                DECIMAL (18, 2)  NOT NULL,
    [RateToPayment]         DECIMAL (24, 12) CONSTRAINT [DF_PaymentLines_Rate] DEFAULT ((1)) NOT NULL,
    [AmountPaymentCurrency] AS               (CONVERT([decimal](18,2),round([Amount]*[RateToPayment],(2)))) PERSISTED,
    [AmountBase]            DECIMAL (18, 2)  CONSTRAINT [DF_PaymentLines_AmountBase] DEFAULT ((0)) NOT NULL,
    [CashBankAccountId]     INT              NOT NULL,
    [Reference]             NVARCHAR (100)   NULL,
    [ChequeNo]              NVARCHAR (50)    NULL,
    [ChequeDate]            DATE             NULL,
    [ChequeDueDate]         DATE             NULL,
    [ClearanceStatus]       TINYINT          NULL,
    [ClearanceUpdatedAtUtc] DATETIME2 (3)    NULL,
    [ClearanceUpdatedBy]    INT              NULL,
    CONSTRAINT [PK_PaymentLines] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_PaymentLines_Amount] CHECK ([Amount]>(0)),
    CONSTRAINT [CK_PaymentLines_Clearance] CHECK ([ClearanceStatus] IS NULL OR ([ClearanceStatus]=(3) OR [ClearanceStatus]=(2) OR [ClearanceStatus]=(1))),
    CONSTRAINT [CK_PaymentLines_Rate] CHECK ([RateToPayment]>(0)),
    CONSTRAINT [FK_PaymentLines_Account] FOREIGN KEY ([CashBankAccountId]) REFERENCES [masterdata].[CashBankAccounts] ([Id]),
    CONSTRAINT [FK_PaymentLines_ClearedBy] FOREIGN KEY ([ClearanceUpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_PaymentLines_Currency] FOREIGN KEY ([CurrencyId]) REFERENCES [masterdata].[Currencies] ([Id]),
    CONSTRAINT [FK_PaymentLines_Method] FOREIGN KEY ([PaymentMethodId]) REFERENCES [masterdata].[PaymentMethods] ([Id]),
    CONSTRAINT [FK_PaymentLines_Payment] FOREIGN KEY ([PaymentId]) REFERENCES [purchase].[Payments] ([Id]),
    CONSTRAINT [UQ_PaymentLines_Number] UNIQUE NONCLUSTERED ([PaymentId] ASC, [LineNumber] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_PaymentLines_Method]
    ON [purchase].[PaymentLines]([PaymentMethodId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_PaymentLines_Account]
    ON [purchase].[PaymentLines]([CashBankAccountId] ASC);


GO

