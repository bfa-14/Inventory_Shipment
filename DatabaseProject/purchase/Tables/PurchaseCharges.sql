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
    [RateType]                  TINYINT         CONSTRAINT [DF_PurchaseCharges_RateType] DEFAULT ((1)) NOT NULL,
    [ExchangeRate]              DECIMAL (18, 6) CONSTRAINT [DF_PurchaseCharges_Rate] DEFAULT ((1)) NOT NULL,
    [Amount]                    DECIMAL (18, 2) NOT NULL,
    [AmountBase]                DECIMAL (18, 2) NOT NULL,
    [AllocationMethod]          NVARCHAR (10)   NOT NULL,
    [IncludeInLandedCost]       BIT             NOT NULL,
    [IncludedInSupplierInvoice] BIT             CONSTRAINT [DF_PurchaseCharges_InSupplierInvoice] DEFAULT ((0)) NOT NULL,
    [Notes]                     NVARCHAR (300)  NULL,
    [CreatedAtUtc]              DATETIME2 (3)   CONSTRAINT [DF_PurchaseCharges_CreatedAtUtc] DEFAULT (sysutcdatetime()) NOT NULL,
    [CreatedBy]                 INT             NULL,
    CONSTRAINT [PK_PurchaseCharges] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_PurchaseCharges_Amount] CHECK ([Amount]>=(0)),
    CONSTRAINT [CK_PurchaseCharges_Kind] CHECK ([DocumentKind]=N'LCA' OR [DocumentKind]=N'PINV'),
    CONSTRAINT [CK_PurchaseCharges_Method] CHECK ([AllocationMethod]=N'Manual' OR [AllocationMethod]=N'Volume' OR [AllocationMethod]=N'Weight' OR [AllocationMethod]=N'Quantity' OR [AllocationMethod]=N'Value'),
    CONSTRAINT [FK_PurchaseCharges_Currency] FOREIGN KEY ([CurrencyId]) REFERENCES [masterdata].[Currencies] ([Id]),
    CONSTRAINT [FK_PurchaseCharges_Provider] FOREIGN KEY ([ProviderPartyId]) REFERENCES [masterdata].[Parties] ([Id]),
    CONSTRAINT [FK_PurchaseCharges_Type] FOREIGN KEY ([ChargeTypeId]) REFERENCES [purchase].[ChargeTypes] ([Id]),
    CONSTRAINT [UQ_PurchaseCharges_Line] UNIQUE NONCLUSTERED ([DocumentKind] ASC, [DocumentId] ASC, [LineNumber] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_PurchaseCharges_Document]
    ON [purchase].[PurchaseCharges]([DocumentKind] ASC, [DocumentId] ASC);


GO

