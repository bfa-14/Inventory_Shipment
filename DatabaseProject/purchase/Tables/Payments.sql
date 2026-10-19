CREATE TABLE [purchase].[Payments] (
    [Id]            INT             IDENTITY (1, 1) NOT NULL,
    [PaymentNumber] NVARCHAR (30)   NULL,
    [PaymentDate]   DATE            NOT NULL,
    [PayeeId]       INT             NOT NULL,
    [BranchId]      INT             NOT NULL,
    [PaymentType]   TINYINT         CONSTRAINT [DF_Payments_PaymentType] DEFAULT ((1)) NOT NULL,
    [CurrencyId]    INT             NOT NULL,
    [Amount]        DECIMAL (18, 2) NOT NULL,
    [ExchangeRate]  DECIMAL (18, 6) CONSTRAINT [DF_Payments_Rate] DEFAULT ((1)) NOT NULL,
    [AmountBase]    AS              (CONVERT([decimal](18,2),[Amount]/[ExchangeRate])) PERSISTED,
    [Reference]     NVARCHAR (100)  NULL,
    [Notes]         NVARCHAR (500)  NULL,
    [Status]        TINYINT         CONSTRAINT [DF_Payments_Status] DEFAULT ((1)) NOT NULL,
    [PostedAtUtc]   DATETIME2 (3)   NULL,
    [PostedBy]      INT             NULL,
    [ReversedAtUtc] DATETIME2 (3)   NULL,
    [ReversedBy]    INT             NULL,
    [ReverseReason] NVARCHAR (500)  NULL,
    [CreatedAtUtc]  DATETIME2 (3)   CONSTRAINT [DF_Payments_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]     INT             NULL,
    [UpdatedAtUtc]  DATETIME2 (3)   NULL,
    [UpdatedBy]     INT             NULL,
    [RowVersion]    ROWVERSION      NOT NULL,
    CONSTRAINT [PK_Payments] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_Payments_Amount] CHECK ([Amount]>(0)),
    CONSTRAINT [CK_Payments_PaymentType] CHECK ([PaymentType]=(3) OR [PaymentType]=(2) OR [PaymentType]=(1)),
    CONSTRAINT [CK_Payments_Posting] CHECK ([Status]=(1) OR [PostedAtUtc] IS NOT NULL AND [PostedBy] IS NOT NULL),
    CONSTRAINT [CK_Payments_Rate] CHECK ([ExchangeRate]>(0)),
    CONSTRAINT [CK_Payments_Reversal] CHECK ([Status]<>(3) OR [ReversedAtUtc] IS NOT NULL AND [ReversedBy] IS NOT NULL),
    CONSTRAINT [CK_Payments_Status] CHECK ([Status]=(3) OR [Status]=(2) OR [Status]=(1)),
    CONSTRAINT [FK_Payments_Branch] FOREIGN KEY ([BranchId]) REFERENCES [masterdata].[Branches] ([Id]),
    CONSTRAINT [FK_Payments_CreatedBy] FOREIGN KEY ([CreatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Payments_Currency] FOREIGN KEY ([CurrencyId]) REFERENCES [masterdata].[Currencies] ([Id]),
    CONSTRAINT [FK_Payments_Payee] FOREIGN KEY ([PayeeId]) REFERENCES [masterdata].[Parties] ([Id]),
    CONSTRAINT [FK_Payments_PostedBy] FOREIGN KEY ([PostedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Payments_ReversedBy] FOREIGN KEY ([ReversedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_Payments_UpdatedBy] FOREIGN KEY ([UpdatedBy]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_Payments_Number]
    ON [purchase].[Payments]([PaymentNumber] ASC) WHERE ([PaymentNumber] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_Payments_Status]
    ON [purchase].[Payments]([Status] ASC, [PaymentDate] DESC);


GO

CREATE NONCLUSTERED INDEX [IX_Payments_Payee]
    ON [purchase].[Payments]([PayeeId] ASC, [PaymentDate] DESC);


GO

