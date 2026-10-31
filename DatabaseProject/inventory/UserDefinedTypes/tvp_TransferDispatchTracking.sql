CREATE TYPE [inventory].[tvp_TransferDispatchTracking] AS TABLE (
    [TransferOrderLineId] INT            NOT NULL,
    [RowNumber]           INT            NOT NULL,
    [BatchNo]             NVARCHAR (100) NULL,
    [SerialNo]            NVARCHAR (100) NULL,
    [ExpiryDate]          DATE           NULL,
    [QuantityBase]        INT            NOT NULL,
    PRIMARY KEY CLUSTERED ([TransferOrderLineId] ASC, [RowNumber] ASC),
    INDEX [IX_Batch] ([TransferOrderLineId], [BatchNo]),
    INDEX [IX_Serial] ([SerialNo]));


GO

