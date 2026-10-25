/* ================================================================== 17. Undoing a receipt names the transfer that moved its goods (FB rule 39) */

/* (90) A GOODS RECEIPT OR AN INVENTORY IN CANNOT BE UNDONE ONCE ITS STOCK HAS LEFT ITS WAREHOUSE, and a transfer may be
   what took it: the refusal now says so, and what to do. No logic changes - each refusal keeps its number, its test and
   its first sentence, and gains inventory.fn_Transfer_MovedOutNote at its end: the posted, not reversed dispatches that
   took the item out of that warehouse since the document was posted, " 80 pcs were moved by TRD-BR-003-000004: transfer
   them back first." (they cover the shortfall) or " (10 of them were moved by TRD-BR-003-000004.)" (they do not); nothing
   when no transfer moved it. Unchanged on purpose (M9): the purchase return 65007, Cancel Offload, the sales return
   cancel, the cancel of a purchase invoice posted before goods receipts. */

-- Re-created (90) from the body of script 64: + the transfer note on Seq 5 (63007), since the receipt's PostedAtUtc.
-- fn_GoodsReceipt_Blocks reads it, so the receipt page's disabled Cancel says it too.
/* THE REFUSALS OF usp_GoodsReceipt_Cancel that can be told before it runs (Get shows the first as
   CancelBlockedReason). The reason, the RowVersion and the purchase returns (63010, known only once the matches are
   rebuilt without this receipt) are checked by the procedure itself.
     63008  its cost was adjusted afterwards: a GRNCOST change of its lines other than the NEGSTOCK of its own posting,
            or, for a container, a late charge (CNTCHARGE) - as 69018 for the offload
     63007  per item and warehouse: the stock on hand is less than what it brought (90: and the transfers that moved it) */
CREATE   FUNCTION purchase.fn_GoodsReceipt_CancelCheck (@Id INT)
RETURNS TABLE
AS
RETURN
WITH h AS
(
    SELECT g.Id, g.Status, g.ContainerId, c.ContainerRef, CtStatus = c.Status,
           g.PostedAtUtc                                                    -- (90) since when a transfer moved its goods away
    FROM purchase.GoodsReceipts g
    LEFT JOIN logistics.Containers c ON c.Id = g.ContainerId
    WHERE g.Id = @Id
)
SELECT x.Seq, x.ErrorNumber, x.Message
FROM
(
    SELECT Seq = 1, ErrorNumber = 63006, Message = CAST(N'Goods receipt not found.' AS NVARCHAR(400))
    WHERE NOT EXISTS (SELECT 1 FROM h)

    UNION ALL
    SELECT 2, 63010, N'Only a posted goods receipt can be cancelled.' FROM h WHERE h.Status <> 2

    UNION ALL
    SELECT 3, 63010, N'Container ' + h.ContainerRef + N' is closed. Reopen it before cancelling its goods receipt.'
    FROM h WHERE h.CtStatus = 7

    UNION ALL
    SELECT 4, 63008, N'The cost of these goods was adjusted after they were received (invoice price, landed cost or a late container charge). This goods receipt can no longer be cancelled.'
    FROM h
    WHERE EXISTS (SELECT 1 FROM purchase.GoodsReceiptCostChanges cc
                  INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = cc.GoodsReceiptLineId
                  WHERE gl.GoodsReceiptId = h.Id AND cc.CauseKind <> N'NEGSTOCK')
       OR EXISTS (SELECT 1 FROM inventory.CostAdjustments ca
                  INNER JOIN logistics.ContainerCharges ch ON ch.Id = ca.SourceId
                  WHERE ca.SourceKind = N'CNTCHARGE' AND ch.ContainerId = h.ContainerId)

    UNION ALL
    SELECT * FROM (SELECT TOP (1) Seq = 5, ErrorNumber = 63007,
                          -- (90) + the dispatches that moved the goods away since the receipt was posted (FB rule 39). The
                          --      message keeps its type, NVARCHAR(400), which fn_GoodsReceipt_Blocks and the cancel read.
                          Message = CAST(N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                    + CAST(oh.Q AS NVARCHAR(20)) + N' left, but this goods receipt brought ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
                                    + ISNULL(inventory.fn_Transfer_MovedOutNote(x.ItemId, x.WarehouseId, h.PostedAtUtc, x.Qty - oh.Q), N'')
                                    AS NVARCHAR(400))
                   FROM h
                   CROSS APPLY (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
                                FROM inventory.StockMovements m
                                WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'GRN' AND m.DocumentId = h.Id AND m.IsReversal = 0
                                GROUP BY m.ItemId, m.WarehouseId) x
                   CROSS APPLY (SELECT Q = inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)) oh
                   INNER JOIN inventory.Items i       ON i.Id = x.ItemId
                   INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
                   WHERE h.Status = 2 AND x.Qty > oh.Q
                   ORDER BY i.ItemCode, w.WarehouseCode) a
) x;

GO

