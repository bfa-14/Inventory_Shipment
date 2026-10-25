CREATE TABLE [inventory].[TransferPostingTracking] (
    [Id]                 INT           IDENTITY (1, 1) NOT NULL,
    [PostingLineId]      INT           NOT NULL,
    [PostingId]          INT           NOT NULL,
    [ItemId]             INT           NOT NULL,
    [RowNumber]          INT           NOT NULL,
    [Kind]               TINYINT       NOT NULL,
    [BatchNo]            NVARCHAR (50) NULL,
    [SerialNo]           NVARCHAR (50) NULL,
    [ExpiryDate]         DATE          NULL,
    [QuantityBase]       INT           NOT NULL,
    [LostBase]           INT           CONSTRAINT [DF_TransferPostingTracking_Lost] DEFAULT ((0)) NOT NULL,
    [SettledBase]        INT           CONSTRAINT [DF_TransferPostingTracking_Settled] DEFAULT ((0)) NOT NULL,
    [DispatchTrackingId] INT           NULL,
    CONSTRAINT [PK_TransferPostingTracking] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [CK_TransferPostingTracking_Blank] CHECK (len(isnull([BatchNo],N'x'))>(0) AND len(isnull([SerialNo],N'x'))>(0)),
    CONSTRAINT [CK_TransferPostingTracking_Expiry] CHECK ([ExpiryDate] IS NULL OR [ExpiryDate]>='20000101' AND [ExpiryDate]<='20991231'),
    CONSTRAINT [CK_TransferPostingTracking_Kind] CHECK ([Kind]=(3) OR [Kind]=(2) OR [Kind]=(1)),
    CONSTRAINT [CK_TransferPostingTracking_Qty] CHECK ([QuantityBase]>=(0) AND [LostBase]>=(0) AND [SettledBase]>=(0) AND ([DispatchTrackingId] IS NULL AND [QuantityBase]>(0) AND [LostBase]=(0) AND [SettledBase]<=[QuantityBase] OR [DispatchTrackingId] IS NOT NULL AND ([QuantityBase]+[LostBase])>(0) AND [SettledBase]=(0))),
    CONSTRAINT [CK_TransferPostingTracking_Serial] CHECK ([Kind]<>(2) OR [DispatchTrackingId] IS NULL AND [QuantityBase]=(1) OR [DispatchTrackingId] IS NOT NULL AND ([QuantityBase]+[LostBase])=(1)),
    CONSTRAINT [CK_TransferPostingTracking_Shape] CHECK ([Kind]=(1) AND [BatchNo] IS NOT NULL AND [SerialNo] IS NULL OR [Kind]=(2) AND [SerialNo] IS NOT NULL AND [BatchNo] IS NULL OR [Kind]=(3) AND [BatchNo] IS NULL AND [SerialNo] IS NULL AND [ExpiryDate] IS NOT NULL),
    CONSTRAINT [FK_TransferPostingTracking_Dispatch] FOREIGN KEY ([DispatchTrackingId]) REFERENCES [inventory].[TransferPostingTracking] ([Id]),
    CONSTRAINT [FK_TransferPostingTracking_Item] FOREIGN KEY ([ItemId]) REFERENCES [inventory].[Items] ([Id]),
    CONSTRAINT [FK_TransferPostingTracking_Line] FOREIGN KEY ([PostingLineId]) REFERENCES [inventory].[TransferPostingLines] ([Id]),
    CONSTRAINT [FK_TransferPostingTracking_Posting] FOREIGN KEY ([PostingId]) REFERENCES [inventory].[TransferPostings] ([Id])
);


GO

CREATE NONCLUSTERED INDEX [IX_TransferPostingTracking_BatchNo]
    ON [inventory].[TransferPostingTracking]([BatchNo] ASC)
    INCLUDE([ItemId], [PostingId], [ExpiryDate]) WHERE ([BatchNo] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_TransferPostingTracking_Dispatch]
    ON [inventory].[TransferPostingTracking]([DispatchTrackingId] ASC) WHERE ([DispatchTrackingId] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_TransferPostingTracking_ItemSerial]
    ON [inventory].[TransferPostingTracking]([ItemId] ASC, [SerialNo] ASC)
    INCLUDE([PostingId], [QuantityBase], [LostBase], [SettledBase], [DispatchTrackingId]) WHERE ([SerialNo] IS NOT NULL);


GO

CREATE NONCLUSTERED INDEX [IX_TransferPostingTracking_Posting]
    ON [inventory].[TransferPostingTracking]([PostingId] ASC, [PostingLineId] ASC);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_TransferPostingTracking_Batch]
    ON [inventory].[TransferPostingTracking]([PostingLineId] ASC, [BatchNo] ASC) WHERE ([BatchNo] IS NOT NULL);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_TransferPostingTracking_ExpiryRow]
    ON [inventory].[TransferPostingTracking]([PostingLineId] ASC, [ExpiryDate] ASC) WHERE ([Kind]=(3));


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_TransferPostingTracking_Number]
    ON [inventory].[TransferPostingTracking]([PostingLineId] ASC, [RowNumber] ASC);


GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_TransferPostingTracking_Serial]
    ON [inventory].[TransferPostingTracking]([PostingId] ASC, [ItemId] ASC, [SerialNo] ASC) WHERE ([SerialNo] IS NOT NULL);


GO

