CREATE TYPE [purchase].[tvp_PaymentAllocation] AS TABLE (
    [DocumentKind]  NVARCHAR (10)    NOT NULL,
    [DocumentId]    INT              NOT NULL,
    [Amount]        DECIMAL (18, 2)  NOT NULL,
    [RateToPayment] DECIMAL (24, 12) NULL,
    PRIMARY KEY CLUSTERED ([DocumentKind] ASC, [DocumentId] ASC));


GO

