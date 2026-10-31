CREATE TYPE [inventory].[tvp_TransferDispatchLine] AS TABLE (
    [TransferOrderLineId] INT NOT NULL,
    [QuantityBase]        INT NOT NULL,
    PRIMARY KEY CLUSTERED ([TransferOrderLineId] ASC));


GO

