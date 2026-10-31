CREATE TYPE [purchase].[tvp_GoodsReceiptLine] AS TABLE (
    [LineNumber]           INT             NOT NULL,
    [ItemId]               INT             NOT NULL,
    [ItemUnitId]           INT             NOT NULL,
    [Quantity]             INT             NOT NULL,
    [WarehouseId]          INT             NULL,
    [PoLineId]             INT             NULL,
    [InvoiceLineId]        INT             NULL,
    [ContainerLineId]      INT             NULL,
    [ExpectedQuantityBase] INT             NULL,
    [VarianceReasonCode]   NVARCHAR (20)   NULL,
    [VarianceReason]       NVARCHAR (300)  NULL,
    [CloseShort]           BIT             NULL,
    [ManualUnitCostBase]   DECIMAL (18, 6) NULL,
    [ExpiryDate]           DATE            NULL,
    [Notes]                NVARCHAR (300)  NULL,
    PRIMARY KEY CLUSTERED ([LineNumber] ASC));


GO

