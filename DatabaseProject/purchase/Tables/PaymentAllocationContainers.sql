CREATE TABLE [purchase].[PaymentAllocationContainers] (
    [Id]                  INT             IDENTITY (1, 1) NOT NULL,
    [PaymentAllocationId] INT             NOT NULL,
    [ContainerId]         INT             NULL,
    [AmountDocCurrency]   DECIMAL (18, 2) NOT NULL,
    [ContainerKey]        AS              (isnull([ContainerId],(0))) PERSISTED NOT NULL,
    CONSTRAINT [PK_PaymentAllocationContainers] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_PaymentAllocationContainers_Amount] CHECK ([AmountDocCurrency]>(0)),
    CONSTRAINT [FK_PaymentAllocationContainers_Allocation] FOREIGN KEY ([PaymentAllocationId]) REFERENCES [purchase].[PaymentAllocations] ([Id]) ON DELETE CASCADE,
    CONSTRAINT [FK_PaymentAllocationContainers_Container] FOREIGN KEY ([ContainerId]) REFERENCES [logistics].[Containers] ([Id]),
    CONSTRAINT [UQ_PaymentAllocationContainers] UNIQUE NONCLUSTERED ([PaymentAllocationId] ASC, [ContainerKey] ASC)
);


GO

