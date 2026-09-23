CREATE TYPE [inventory].[tvp_ShortageLine] AS TABLE (
    [LineNumber]                 INT             NOT NULL,
    [ItemId]                     INT             NOT NULL,
    [RequiredQty]                INT             NULL,
    [ExpectedMonthlySalesManual] DECIMAL (18, 2) NULL,
    [PcPerContainer]             INT             NULL,
    [Notes]                      NVARCHAR (300)  NULL,
    PRIMARY KEY CLUSTERED ([LineNumber] ASC));


GO

