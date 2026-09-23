CREATE TABLE [purchase].[PurchaseChargeAllocations] (
    [Id]             INT             IDENTITY (1, 1) NOT NULL,
    [ChargeId]       INT             NOT NULL,
    [PurchaseLineId] INT             NOT NULL,
    [Basis]          DECIMAL (18, 6) NULL,
    [AmountBase]     DECIMAL (18, 2) NOT NULL,
    [IsManual]       BIT             CONSTRAINT [DF_PurchaseChargeAllocations_Manual] DEFAULT ((0)) NOT NULL,
    CONSTRAINT [PK_PurchaseChargeAllocations] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [FK_PurchaseChargeAllocations_Charge] FOREIGN KEY ([ChargeId]) REFERENCES [purchase].[PurchaseCharges] ([Id]),
    CONSTRAINT [FK_PurchaseChargeAllocations_Line] FOREIGN KEY ([PurchaseLineId]) REFERENCES [purchase].[PurchaseDocumentLines] ([Id]),
    CONSTRAINT [UQ_PurchaseChargeAllocations] UNIQUE NONCLUSTERED ([ChargeId] ASC, [PurchaseLineId] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_PurchaseChargeAllocations_Line]
    ON [purchase].[PurchaseChargeAllocations]([PurchaseLineId] ASC);


GO

