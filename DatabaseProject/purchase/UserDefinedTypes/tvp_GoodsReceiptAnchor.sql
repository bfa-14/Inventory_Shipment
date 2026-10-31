CREATE TYPE [purchase].[tvp_GoodsReceiptAnchor] AS TABLE (
    [Kind]       CHAR (1) NOT NULL,
    [PoLineId]   INT      NULL,
    [SupplierId] INT      NULL,
    [ItemId]     INT      NULL,
    CHECK ([Kind]='P' AND [PoLineId] IS NOT NULL OR [Kind]='S' AND [SupplierId] IS NOT NULL AND [ItemId] IS NOT NULL));


GO

