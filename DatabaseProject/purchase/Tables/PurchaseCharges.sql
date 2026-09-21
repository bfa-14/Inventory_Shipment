CREATE TABLE [purchase].[PurchaseCharges] (
    [Id]                        INT             IDENTITY (1, 1) NOT NULL,
    [DocumentKind]              NVARCHAR (10)   NOT NULL,
    [DocumentId]                INT             NOT NULL,
    [LineNumber]                INT             NOT NULL,
    [ChargeTypeId]              INT             NOT NULL,
    [Description]               NVARCHAR (200)  NULL,
    [ProviderPartyId]           INT             NULL,
    [Reference]                 NVARCHAR (100)  NULL,
    [CurrencyId]                INT             NOT NULL,
    [RateType]                  TINYINT         NOT NULL,
    [ExchangeRate]              DECIMAL (18, 6) NOT NULL,
    [Amount]                    DECIMAL (18, 2) NOT NULL,
    [AmountBase]                DECIMAL (18, 2) NOT NULL,
    [AllocationMethod]          NVARCHAR (10)   NOT NULL,
    [IncludeInLandedCost]       BIT             NOT NULL,
    [IncludedInSupplierInvoice] BIT             NOT NULL,
    [Notes]                     NVARCHAR (300)  NULL,
    [CreatedAtUtc]              DATETIME2 (3)   NOT NULL,
    [CreatedBy]                 INT             NULL
);
GO

ALTER TABLE [purchase].[PurchaseCharges]
    ADD CONSTRAINT [FK_PurchaseCharges_Provider] FOREIGN KEY ([ProviderPartyId]) REFERENCES [masterdata].[Parties] ([Id]);
GO

ALTER TABLE [purchase].[PurchaseCharges]
    ADD CONSTRAINT [FK_PurchaseCharges_Currency] FOREIGN KEY ([CurrencyId]) REFERENCES [masterdata].[Currencies] ([Id]);
GO

ALTER TABLE [purchase].[PurchaseCharges]
    ADD CONSTRAINT [FK_PurchaseCharges_Type] FOREIGN KEY ([ChargeTypeId]) REFERENCES [purchase].[ChargeTypes] ([Id]);
GO

ALTER TABLE [purchase].[PurchaseCharges]
    ADD CONSTRAINT [PK_PurchaseCharges] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

CREATE NONCLUSTERED INDEX [IX_PurchaseCharges_Document]
    ON [purchase].[PurchaseCharges]([DocumentKind] ASC, [DocumentId] ASC);
GO

ALTER TABLE [purchase].[PurchaseCharges]
    ADD CONSTRAINT [DF_PurchaseCharges_InSupplierInvoice] DEFAULT ((0)) FOR [IncludedInSupplierInvoice];
GO

ALTER TABLE [purchase].[PurchaseCharges]
    ADD CONSTRAINT [DF_PurchaseCharges_RateType] DEFAULT ((1)) FOR [RateType];
GO

ALTER TABLE [purchase].[PurchaseCharges]
    ADD CONSTRAINT [DF_PurchaseCharges_CreatedAtUtc] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];
GO

ALTER TABLE [purchase].[PurchaseCharges]
    ADD CONSTRAINT [DF_PurchaseCharges_Rate] DEFAULT ((1)) FOR [ExchangeRate];
GO

ALTER TABLE [purchase].[PurchaseCharges]
    ADD CONSTRAINT [UQ_PurchaseCharges_Line] UNIQUE NONCLUSTERED ([DocumentKind] ASC, [DocumentId] ASC, [LineNumber] ASC);
GO

ALTER TABLE [purchase].[PurchaseCharges]
    ADD CONSTRAINT [CK_PurchaseCharges_Amount] CHECK ([Amount]>=(0));
GO

ALTER TABLE [purchase].[PurchaseCharges]
    ADD CONSTRAINT [CK_PurchaseCharges_Method] CHECK ([AllocationMethod]=N'Manual' OR [AllocationMethod]=N'Volume' OR [AllocationMethod]=N'Weight' OR [AllocationMethod]=N'Quantity' OR [AllocationMethod]=N'Value');
GO

ALTER TABLE [purchase].[PurchaseCharges]
    ADD CONSTRAINT [CK_PurchaseCharges_Kind] CHECK ([DocumentKind]=N'LCA' OR [DocumentKind]=N'PINV');
GO

