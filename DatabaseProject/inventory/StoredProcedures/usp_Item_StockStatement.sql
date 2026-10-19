/* ================================================================== 21. Item stock statement: goods receipt rows */

-- Re-created (65) from the body of script 58: a goods receipt (type GRN) is not a purchase document, so the
-- purchase-document join leaves it out (its id is a goods receipt id, not a document id). Its counterparty is the
-- supplier of the receipt line (a container of several suppliers has one per line), else of the receipt; and the new
-- column SourceReference names where the goods came from: the container, else the order, else the invoice (a receipt
-- made from an invoice without an order). NULL on every other row.
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
           Counterparty = COALESCE(cl.PartyName, sp.PartyName),
           -- (65) a goods receipt's source: its container, else its order, else its invoice
           SourceReference = CASE WHEN gr.Id IS NOT NULL THEN COALESCE(gc.ContainerRef, gpo.DocumentNumber, gpi.DocumentNumber) END,
           CreatedByName = u.FullName
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
    LEFT JOIN security.Users u ON u.Id = m.CreatedBy
    WHERE m.ItemId = @ItemId
      AND (@DateFrom IS NULL OR m.MovementDate >= @DateFrom)
      AND (@DateTo IS NULL OR m.MovementDate < DATEADD(DAY, 1, @DateTo))
    ORDER BY m.MovementDate, m.Id;
END

GO

