CREATE TABLE [inventory].[TransferOrderLines] (
    [Id]              INT            IDENTITY (1, 1) NOT NULL,
    [TransferOrderId] INT            NOT NULL,
    [LineNumber]      INT            NOT NULL,
    [ItemId]          INT            NOT NULL,
    [ItemUnitId]      INT            NOT NULL,
    [Quantity]        INT            NOT NULL,
    [PackingFormula]  INT            NOT NULL,
    [OrderedBase]     AS             ([Quantity]*[PackingFormula]) PERSISTED,
    [Notes]           NVARCHAR (300) NULL,
    [DispatchedBase]  INT            CONSTRAINT [DF_TransferOrderLines_Dispatched] DEFAULT ((0)) NOT NULL,
    [ReceivedBase]    INT            CONSTRAINT [DF_TransferOrderLines_Received] DEFAULT ((0)) NOT NULL,
    [LostBase]        INT            CONSTRAINT [DF_TransferOrderLines_Lost] DEFAULT ((0)) NOT NULL,
    [NotSentBase]     INT            CONSTRAINT [DF_TransferOrderLines_NotSent] DEFAULT ((0)) NOT NULL,
    CONSTRAINT [PK_TransferOrderLines] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_TransferOrderLines_Counters] CHECK ([DispatchedBase]>=(0) AND [ReceivedBase]>=(0) AND [LostBase]>=(0) AND [NotSentBase]>=(0) AND ([ReceivedBase]+[LostBase])<=[DispatchedBase] AND ([DispatchedBase]+[NotSentBase])<=[Quantity]*[PackingFormula]),
    CONSTRAINT [CK_TransferOrderLines_Formula] CHECK ([PackingFormula]>=(1)),
    CONSTRAINT [CK_TransferOrderLines_Qty] CHECK ([Quantity]>(0)),
    CONSTRAINT [FK_TransferOrderLines_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]),
    CONSTRAINT [FK_TransferOrderLines_Order] FOREIGN KEY ([TransferOrderId]) REFERENCES [inventory].[TransferOrders] ([Id]),
    CONSTRAINT [FK_TransferOrderLines_Unit] FOREIGN KEY ([ItemUnitId]) REFERENCES [inventory].[ItemUnits] ([Id]),
    CONSTRAINT [UQ_TransferOrderLines_LineNo] UNIQUE NONCLUSTERED ([TransferOrderId] ASC, [LineNumber] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_TransferOrderLines_Item]
    ON [inventory].[TransferOrderLines]([ItemId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_TransferOrderLines_Order]
    ON [inventory].[TransferOrderLines]([TransferOrderId] ASC)
    INCLUDE([ItemId], [DispatchedBase], [ReceivedBase], [LostBase], [NotSentBase]);


GO

