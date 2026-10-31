CREATE TYPE [inventory].[tvp_TransferReceiptTracking] AS TABLE (
    [DispatchTrackingId] INT NOT NULL,
    [ReceivedBase]       INT NOT NULL,
    [LostBase]           INT NOT NULL,
    PRIMARY KEY CLUSTERED ([DispatchTrackingId] ASC));


GO

