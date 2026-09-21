CREATE TABLE [purchase].[PurchaseChargeAllocations] (
    [Id]             INT             IDENTITY (1, 1) NOT NULL,
    [ChargeId]       INT             NOT NULL,
    [PurchaseLineId] INT             NOT NULL,
    [Basis]          DECIMAL (18, 6) NULL,
    [AmountBase]     DECIMAL (18, 2) NOT NULL,
    [IsManual]       BIT             NOT NULL
);
GO

ALTER TABLE [purchase].[PurchaseChargeAllocations]
    ADD CONSTRAINT [PK_PurchaseChargeAllocations] PRIMARY KEY CLUSTERED ([Id] ASC);
GO

ALTER TABLE [purchase].[PurchaseChargeAllocations]
    ADD CONSTRAINT [UQ_PurchaseChargeAllocations] UNIQUE NONCLUSTERED ([ChargeId] ASC, [PurchaseLineId] ASC);
GO

ALTER TABLE [purchase].[PurchaseChargeAllocations]
    ADD CONSTRAINT [FK_PurchaseChargeAllocations_Charge] FOREIGN KEY ([ChargeId]) REFERENCES [purchase].[PurchaseCharges] ([Id]);
GO

ALTER TABLE [purchase].[PurchaseChargeAllocations]
    ADD CONSTRAINT [FK_PurchaseChargeAllocations_Line] FOREIGN KEY ([PurchaseLineId]) REFERENCES [purchase].[PurchaseDocumentLines] ([Id]);
GO

ALTER TABLE [purchase].[PurchaseChargeAllocations]
    ADD CONSTRAINT [DF_PurchaseChargeAllocations_Manual] DEFAULT ((0)) FOR [IsManual];
GO

CREATE NONCLUSTERED INDEX [IX_PurchaseChargeAllocations_Line]
    ON [purchase].[PurchaseChargeAllocations]([PurchaseLineId] ASC);
GO

