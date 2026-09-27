CREATE TABLE [logistics].[ContainerChargeAllocations] (
    [Id]              INT             IDENTITY (1, 1) NOT NULL,
    [ChargeId]        INT             NOT NULL,
    [ContainerLineId] INT             NOT NULL,
    [Basis]           DECIMAL (18, 6) NULL,
    [AmountBase]      DECIMAL (18, 2) NOT NULL,
    [IsManual]        BIT             CONSTRAINT [DF_ContainerChargeAllocations_Manual] DEFAULT ((0)) NOT NULL,
    CONSTRAINT [PK_ContainerChargeAllocations] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_ContainerChargeAllocations_Amount] CHECK ([AmountBase]>=(0)),
    CONSTRAINT [FK_ContainerChargeAllocations_Charge] FOREIGN KEY ([ChargeId]) REFERENCES [logistics].[ContainerCharges] ([Id]),
    CONSTRAINT [FK_ContainerChargeAllocations_Line] FOREIGN KEY ([ContainerLineId]) REFERENCES [logistics].[ContainerLines] ([Id]),
    CONSTRAINT [UQ_ContainerChargeAllocations] UNIQUE NONCLUSTERED ([ChargeId] ASC, [ContainerLineId] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_ContainerChargeAllocations_Line]
    ON [logistics].[ContainerChargeAllocations]([ContainerLineId] ASC);


GO

