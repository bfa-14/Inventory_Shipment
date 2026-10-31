/* ================================================================== 15. Item stock statement: the transfer rows */

-- Re-created (90) from the body of script 65: + a transfer row (family Transfer, a dispatch TRD or a receipt TRR) says
-- where the goods went, "LKS-01 -> LUB-01" (the posting's From and To, both legs of it alike) in Counterparty, the
-- transfer order's number in SourceReference, and the order's id in the new last column TransferOrderId (the page's
-- link). NULL on every other row; every other column and row unchanged.
CREATE   PROCEDURE inventory.usp_Item_StockStatement
    @ItemId      INT,
    @DateFrom    DATE = NULL,
    @DateTo      DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Opening INT =
        CASE WHEN @DateFrom IS NULL THEN 0 ELSE
            (SELECT ISNULL(SUM(m.QuantityBase), 0) FROM inventory.StockMovements m
             WHERE m.ItemId = @ItemId AND m.MovementDate < @DateFrom) END;

    SELECT OpeningBase = @Opening;

    SELECT m.Id, m.MovementDate, m.DocumentFamily, m.DocumentTypeCode, DocumentTypeName = dt.Name,
           m.DocumentId, m.DocumentNumber, m.IsReversal, m.ReasonCode, m.ExpiryDate,
           m.WarehouseId, w.WarehouseCode, w.WarehouseName, br.BranchName,
           QuantityIn  = CASE WHEN m.QuantityBase > 0 THEN m.QuantityBase ELSE 0 END,
           QuantityOut = CASE WHEN m.QuantityBase < 0 THEN -m.QuantityBase ELSE 0 END,
           Balance     = @Opening + SUM(m.QuantityBase) OVER (ORDER BY m.MovementDate, m.Id ROWS UNBOUNDED PRECEDING),
           m.UnitCostBase,
           -- who the stock went to or came from: the client of a sale, the supplier of a purchase
           Counterparty = COALESCE(cl.PartyName, sp.PartyName,
                                   -- (90) a transfer row: where the goods went, the posting's From -> To ("LKS-01 -> LUB-01")
                                   CASE WHEN tp.Id IS NOT NULL THEN fw.WarehouseCode + N' ' + NCHAR(8594) + N' ' + tw.WarehouseCode END),
           -- (65) a goods receipt's source: its container, else its order, else its invoice
           --      (90) a transfer row's: its transfer order
           SourceReference = CASE WHEN gr.Id IS NOT NULL THEN COALESCE(gc.ContainerRef, gpo.DocumentNumber, gpi.DocumentNumber)
                                  WHEN tro.Id IS NOT NULL THEN tro.DocumentNumber END,
           CreatedByName = u.FullName,
           TransferOrderId = tro.Id                                         -- (90) a TRD / TRR row: its transfer order (the link)
    FROM inventory.StockMovements m
    INNER JOIN masterdata.Warehouses w ON w.Id = m.WarehouseId
    INNER JOIN masterdata.Branches br  ON br.Id = w.BranchId
    LEFT JOIN inventory.DocumentTypes dt ON dt.Code = m.DocumentTypeCode
    LEFT JOIN sales.SalesDocuments sd ON m.DocumentFamily = N'Sales' AND sd.Id = m.DocumentId
    LEFT JOIN masterdata.Parties cl ON cl.Id = sd.ClientId
    LEFT JOIN purchase.PurchaseDocuments pd ON m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode NOT IN (N'CNT', N'GRN') AND pd.Id = m.DocumentId
    -- (65) a goods receipt row: the receipt, its line (the stock row's line), its container, order and invoice
    LEFT JOIN purchase.GoodsReceipts gr ON m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'GRN' AND gr.Id = m.DocumentId
    LEFT JOIN purchase.GoodsReceiptLines grl ON grl.Id = m.DocumentLineId AND grl.GoodsReceiptId = gr.Id
    LEFT JOIN logistics.Containers gc ON gc.Id = gr.ContainerId
    LEFT JOIN purchase.PurchaseDocuments gpo ON gpo.Id = COALESCE(grl.PurchaseOrderId, gr.PurchaseOrderId)
    LEFT JOIN purchase.PurchaseDocuments gpi ON gpi.Id = gr.PurchaseInvoiceId
    LEFT JOIN masterdata.Parties sp ON sp.Id = COALESCE(pd.SupplierId, grl.SupplierId, gr.SupplierId)
    -- (90) a transfer row (family Transfer, TRD / TRR): its dispatch or receipt, the order, and the posting's From / To
    LEFT JOIN inventory.TransferPostings tp ON m.DocumentFamily = N'Transfer' AND tp.Id = m.DocumentId
    LEFT JOIN inventory.TransferOrders tro  ON tro.Id = tp.TransferOrderId
    LEFT JOIN masterdata.Warehouses fw      ON fw.Id = tp.FromWarehouseId
    LEFT JOIN masterdata.Warehouses tw      ON tw.Id = tp.ToWarehouseId
    LEFT JOIN security.Users u ON u.Id = m.CreatedBy
    WHERE m.ItemId = @ItemId
      AND (@DateFrom IS NULL OR m.MovementDate >= @DateFrom)
      AND (@DateTo IS NULL OR m.MovementDate < DATEADD(DAY, 1, @DateTo))
    ORDER BY m.MovementDate, m.Id;
END

GO

