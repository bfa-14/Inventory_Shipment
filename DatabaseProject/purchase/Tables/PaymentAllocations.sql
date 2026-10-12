CREATE TABLE [purchase].[PaymentAllocations] (
    [Id]                    INT              IDENTITY (1, 1) NOT NULL,
    [PaymentId]             INT              NOT NULL,
    [DocumentKind]          NVARCHAR (10)    NOT NULL,
    [PurchaseDocumentId]    INT              NULL,
    [ContainerChargeId]     INT              NULL,
    [AmountDocCurrency]     DECIMAL (18, 2)  NOT NULL,
    [DocExchangeRate]       DECIMAL (18, 6)  NOT NULL,
    [AmountBase]            AS               (CONVERT([decimal](18,2),[AmountDocCurrency]/[DocExchangeRate])) PERSISTED,
    [RateToPayment]         DECIMAL (24, 12) CONSTRAINT [DF_PaymentAllocations_Rate] DEFAULT ((1)) NOT NULL,
    [AmountPaymentCurrency] AS               (CONVERT([decimal](18,2),round([AmountDocCurrency]*[RateToPayment],(2)))) PERSISTED,
    [AllocatedAtUtc]        DATETIME2 (3)    CONSTRAINT [DF_PaymentAllocations_At] DEFAULT (sysutcdatetime()) NOT NULL,
    [AllocatedBy]           INT              NULL,
    [RemovedAtUtc]          DATETIME2 (3)    NULL,
    [RemovedBy]             INT              NULL,
    CONSTRAINT [PK_PaymentAllocations] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_PaymentAllocations_Amount] CHECK ([AmountDocCurrency]>(0)),
    CONSTRAINT [CK_PaymentAllocations_DocRate] CHECK ([DocExchangeRate]>(0)),
    CONSTRAINT [CK_PaymentAllocations_Kind] CHECK ([DocumentKind]=N'PINV' AND [PurchaseDocumentId] IS NOT NULL AND [ContainerChargeId] IS NULL OR [DocumentKind]=N'CHARGE' AND [ContainerChargeId] IS NOT NULL AND [PurchaseDocumentId] IS NULL),
    CONSTRAINT [CK_PaymentAllocations_PayRate] CHECK ([RateToPayment]>(0)),
    CONSTRAINT [CK_PaymentAllocations_Removed] CHECK ([RemovedAtUtc] IS NULL AND [RemovedBy] IS NULL OR [RemovedAtUtc] IS NOT NULL AND [RemovedBy] IS NOT NULL),
    CONSTRAINT [FK_PaymentAllocations_By] FOREIGN KEY ([AllocatedBy]) REFERENCES [security].[Users] ([Id]),
    CONSTRAINT [FK_PaymentAllocations_Charge] FOREIGN KEY ([ContainerChargeId]) REFERENCES [logistics].[ContainerCharges] ([Id]),
    CONSTRAINT [FK_PaymentAllocations_Invoice] FOREIGN KEY ([PurchaseDocumentId]) REFERENCES [purchase].[PurchaseDocuments] ([Id]),
    CONSTRAINT [FK_PaymentAllocations_Payment] FOREIGN KEY ([PaymentId]) REFERENCES [purchase].[Payments] ([Id]),
    CONSTRAINT [FK_PaymentAllocations_RemovedBy] FOREIGN KEY ([RemovedBy]) REFERENCES [security].[Users] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_PaymentAllocations_Invoice]
    ON [purchase].[PaymentAllocations]([PurchaseDocumentId] ASC)
    INCLUDE([PaymentId], [AmountDocCurrency], [RemovedAtUtc]) WHERE ([PurchaseDocumentId] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_PaymentAllocations_Payment]
    ON [purchase].[PaymentAllocations]([PaymentId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_PaymentAllocations_Charge]
    ON [purchase].[PaymentAllocations]([ContainerChargeId] ASC)
    INCLUDE([PaymentId], [AmountDocCurrency], [RemovedAtUtc]) WHERE ([ContainerChargeId] IS NOT NULL);


GO

