CREATE TYPE [logistics].[tvp_ContainerReceipt] AS TABLE (
    [LineId]               INT            NOT NULL,
    [ReceivedQuantityBase] INT            NOT NULL,
    [VarianceReason]       NVARCHAR (200) NULL,
    PRIMARY KEY CLUSTERED ([LineId] ASC));


GO

