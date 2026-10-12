CREATE TYPE [purchase].[tvp_PaymentAllocationContainer] AS TABLE (
    [DocumentId]  INT             NOT NULL,
    [ContainerId] INT             NOT NULL,
    [Amount]      DECIMAL (18, 2) NOT NULL,
    PRIMARY KEY CLUSTERED ([DocumentId] ASC, [ContainerId] ASC));


GO

