CREATE TABLE [masterdata].[CashBankAccounts] (
    [Id]           INT            IDENTITY (1, 1) NOT NULL,
    [AccountCode]  NVARCHAR (20)  NOT NULL,
    [AccountName]  NVARCHAR (100) NOT NULL,
    [AccountType]  NVARCHAR (10)  NOT NULL,
    [CurrencyId]   INT            NOT NULL,
    [BranchId]     INT            NULL,
    [Description]  NVARCHAR (500) NULL,
    [IsActive]     BIT            CONSTRAINT [DF_CashBankAccounts_IsActive] DEFAULT ((1)) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)  CONSTRAINT [DF_CashBankAccounts_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]    INT            NULL,
    [UpdatedAtUtc] DATETIME2 (3)  NULL,
    [UpdatedBy]    INT            NULL,
    [RowVersion]   ROWVERSION     NOT NULL,
    CONSTRAINT [PK_CashBankAccounts] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_CashBankAccounts_Code_NotBlank] CHECK (len(ltrim(rtrim([AccountCode])))>(0)),
    CONSTRAINT [CK_CashBankAccounts_Name_NotBlank] CHECK (len(ltrim(rtrim([AccountName])))>(0)),
    CONSTRAINT [CK_CashBankAccounts_Type] CHECK ([AccountType]=N'Bank' OR [AccountType]=N'Cash'),
    CONSTRAINT [FK_CashBankAccounts_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_CashBankAccounts_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_CashBankAccounts_Currency] FOREIGN KEY ([CurrencyId]) REFERENCES [masterdata].[Currencies] ([Id]),
    CONSTRAINT [FK_CashBankAccounts_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [UQ_CashBankAccounts_Code] UNIQUE NONCLUSTERED ([AccountCode] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_CashBankAccounts_Currency]
    ON [masterdata].[CashBankAccounts]([CurrencyId] ASC, [IsActive] ASC);


GO

