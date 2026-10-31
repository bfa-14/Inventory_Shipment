CREATE TYPE [inventory].[tvp_ShortageLeadTime] AS TABLE (
    [ItemId]         INT            NOT NULL,
    [LeadTimeMonths] DECIMAL (6, 2) NOT NULL,
    PRIMARY KEY CLUSTERED ([ItemId] ASC));


GO

