CREATE TYPE [inventory].[tvp_TransferReceiptLine] AS TABLE (
    [DispatchLineId]        INT            NOT NULL,
    [ReceivedBase]          INT            NOT NULL,
    [NothingMoreWillArrive] BIT            NOT NULL,
    [LossReasonCode]        NVARCHAR (20)  NULL,
    [LossNote]              NVARCHAR (300) NULL,
    PRIMARY KEY CLUSTERED ([DispatchLineId] ASC));


GO

