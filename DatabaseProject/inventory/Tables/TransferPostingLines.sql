CREATE TABLE [inventory].[TransferPostingLines] (
    [Id]                  INT             IDENTITY (1, 1) NOT NULL,
    [PostingId]           INT             NOT NULL,
    [LineNumber]          INT             NOT NULL,
    [TransferOrderLineId] INT             NOT NULL,
    [ItemId]              INT             NOT NULL,
    [DispatchLineId]      INT             NULL,
    [TransitWarehouseId]  INT             NOT NULL,
    [QuantityBase]        INT             NOT NULL,
    [LostBase]            INT             CONSTRAINT [DF_TransferPostingLines_Lost] DEFAULT ((0)) NOT NULL,
    [LossReasonCode]      NVARCHAR (20)   NULL,
    [LossNote]            NVARCHAR (300)  NULL,
    [SettledBase]         INT             CONSTRAINT [DF_TransferPostingLines_Settled] DEFAULT ((0)) NOT NULL,
    [UnitCostBase]        DECIMAL (18, 6) NULL,
    [LossUnitCostBase]    DECIMAL (18, 6) NULL,
    CONSTRAINT [PK_TransferPostingLines] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_TransferPostingLines_Lost] CHECK ([LostBase]>=(0) AND ([DispatchLineId] IS NOT NULL OR [LostBase]=(0)) AND ([LostBase]=(0) OR [LossReasonCode] IS NOT NULL)),
    CONSTRAINT [CK_TransferPostingLines_Qty] CHECK ([QuantityBase]>=(0) AND ([DispatchLineId] IS NOT NULL OR [QuantityBase]>(0))),
    CONSTRAINT [CK_TransferPostingLines_Reason] CHECK ([LossReasonCode] IS NULL OR ([LossReasonCode]=N'OTHER' OR [LossReasonCode]=N'DISPATCHCOUNT' OR [LossReasonCode]=N'MISSING' OR [LossReasonCode]=N'DAMAGED')),
    CONSTRAINT [CK_TransferPostingLines_Settled] CHECK ([SettledBase]>=(0) AND [SettledBase]<=[QuantityBase] AND ([DispatchLineId] IS NULL OR [SettledBase]=(0))),
    CONSTRAINT [CK_TransferPostingLines_Something] CHECK ([DispatchLineId] IS NULL OR ([QuantityBase]+[LostBase])>(0)),
    CONSTRAINT [FK_TransferPostingLines_Dispatch] FOREIGN KEY ([DispatchLineId]) REFERENCES [inventory].[TransferPostingLines] ([Id]),
    CONSTRAINT [FK_TransferPostingLines_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]),
    CONSTRAINT [FK_TransferPostingLines_OrderLine] FOREIGN KEY ([TransferOrderLineId]) REFERENCES [inventory].[TransferOrderLines] ([Id]),
    CONSTRAINT [FK_TransferPostingLines_Posting] FOREIGN KEY ([PostingId]) REFERENCES [inventory].[TransferPostings] ([Id]),
    CONSTRAINT [FK_TransferPostingLines_Transit] FOREIGN KEY ([TransitWarehouseId]) REFERENCES [masterdata].[Warehouses] ([Id]),
    CONSTRAINT [UQ_TransferPostingLines_LineNo] UNIQUE NONCLUSTERED ([PostingId] ASC, [LineNumber] ASC)
);


GO

CREATE NONCLUSTERED INDEX [IX_TransferPostingLines_Posting]
    ON [inventory].[TransferPostingLines]([PostingId] ASC);


GO

CREATE NONCLUSTERED INDEX [IX_TransferPostingLines_Dispatch]
    ON [inventory].[TransferPostingLines]([DispatchLineId] ASC) WHERE ([DispatchLineId] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_TransferPostingLines_OrderLine]
    ON [inventory].[TransferPostingLines]([TransferOrderLineId] ASC);


GO

