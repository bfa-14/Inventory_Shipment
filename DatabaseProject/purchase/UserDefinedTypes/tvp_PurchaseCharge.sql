CREATE TYPE [purchase].[tvp_PurchaseCharge] AS TABLE (
    [LineNumber]                INT             NOT NULL,
    [ChargeTypeId]              INT             NOT NULL,
    [Description]               NVARCHAR (200)  NULL,
    [ProviderPartyId]           INT             NULL,
    [Reference]                 NVARCHAR (100)  NULL,
    [CurrencyId]                INT             NULL,
    [RateType]                  TINYINT         NULL,
    [ExchangeRate]              DECIMAL (18, 6) NULL,
    [Amount]                    DECIMAL (18, 2) NOT NULL,
    [AllocationMethod]          NVARCHAR (10)   NULL,
    [IncludedInSupplierInvoice] BIT             NULL,
    [Notes]                     NVARCHAR (300)  NULL,
    PRIMARY KEY CLUSTERED ([LineNumber] ASC));
GO

