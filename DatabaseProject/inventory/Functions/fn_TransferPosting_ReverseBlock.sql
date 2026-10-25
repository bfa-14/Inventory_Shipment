--      ReverseDispatch / ReverseReceipt rows of fn_TransferOrder_Blocks): one row per failed rule, the first (lowest
--      Seq) is the reason, none = allowed. Read by usp_TransferPosting_Reverse (thrown as it comes) and by
--      usp_TransferOrder_Get (the posting's ReverseBlockedReason). A RECEIPT BEFORE ITS DISPATCH: a dispatch whose goods
--      a posted receipt took (received or written off) waits for that receipt's reversal; a receipt only while the
--      destination still holds what it brought.
CREATE   FUNCTION inventory.fn_TransferPosting_ReverseBlock (@PostingId INT)
RETURNS TABLE
AS
RETURN
WITH p AS
(
    SELECT tp.Id, tp.Kind, tp.Status, tp.DocumentNumber, tp.ToWarehouseId, tp.TransitWarehouseId
    FROM inventory.TransferPostings tp
    WHERE tp.Id = @PostingId
),
r AS
(
    -- the posted receipts with a line on one of the dispatch's lines
    SELECT rp.Id, rp.DocumentNumber, rp.PostedAtUtc
    FROM inventory.TransferPostings rp
    WHERE rp.Kind = N'Receipt' AND rp.Status = 2
      AND EXISTS (SELECT 1 FROM inventory.TransferPostingLines rl
                  INNER JOIN inventory.TransferPostingLines dl ON dl.Id = rl.DispatchLineId
                  WHERE rl.PostingId = rp.Id AND dl.PostingId = @PostingId)
)
SELECT Seq = CAST(x.Seq AS INT), ErrorNumber = CAST(x.ErrorNumber AS INT), Message = CAST(x.Message AS NVARCHAR(400))
FROM
(
    SELECT Seq = 1, ErrorNumber = 62006, Message = CAST(N'Dispatch or receipt not found.' AS NVARCHAR(400))
    WHERE NOT EXISTS (SELECT 1 FROM p)

    UNION ALL
    SELECT 2, 62010, p.DocumentNumber + N' is already reversed.'
    FROM p WHERE p.Status = 3

    UNION ALL
    SELECT 3, 62013, p.DocumentNumber + N' has goods received by ' + rl.List
                     + CASE WHEN rn.N > 3 THEN N' and ' + CAST(rn.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END
                     + N': reverse that receipt first.'
    FROM p
    CROSS APPLY (SELECT N = COUNT(*) FROM r) rn
    CROSS APPLY (SELECT List = STRING_AGG(t.DocumentNumber, N', ') WITHIN GROUP (ORDER BY t.PostedAtUtc, t.Id)
                 FROM (SELECT TOP (3) r.Id, r.DocumentNumber, r.PostedAtUtc FROM r ORDER BY r.PostedAtUtc, r.Id) t) rl
    WHERE p.Kind = N'Dispatch' AND p.Status = 2 AND rn.N > 0

    UNION ALL
    -- a receipt, per item: the destination must still hold what it brought
    SELECT * FROM (SELECT TOP (1) Seq = 4, ErrorNumber = 62007,
                          Message = N'Cannot reverse: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                    + CAST(oh.Q AS NVARCHAR(20)) + N' left, but this receipt brought ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
                   FROM p
                   CROSS APPLY (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
                                FROM inventory.StockMovements m
                                WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = N'TRR' AND m.DocumentId = p.Id
                                  AND m.IsReversal = 0 AND m.WarehouseId = p.ToWarehouseId
                                GROUP BY m.ItemId, m.WarehouseId) x
                   CROSS APPLY (SELECT Q = ISNULL(SUM(s.QuantityBase), 0) FROM inventory.StockMovements s
                                WHERE s.ItemId = x.ItemId AND s.WarehouseId = x.WarehouseId) oh
                   INNER JOIN inventory.Items i       ON i.Id = x.ItemId
                   INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
                   WHERE p.Kind = N'Receipt' AND p.Status = 2 AND x.Qty > oh.Q
                   ORDER BY i.ItemCode) a4

    UNION ALL
    -- a dispatch, per item: the On the way warehouse must still hold what it sent (a safety net: while no posted receipt
    -- took its goods - Seq 3 - they are all still there)
    SELECT * FROM (SELECT TOP (1) Seq = 5, ErrorNumber = 62007,
                          Message = N'Cannot reverse: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                    + CAST(oh.Q AS NVARCHAR(20)) + N' left, but this dispatch sent ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
                   FROM p
                   CROSS APPLY (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
                                FROM inventory.StockMovements m
                                WHERE m.DocumentFamily = N'Transfer' AND m.DocumentTypeCode = N'TRD' AND m.DocumentId = p.Id
                                  AND m.IsReversal = 0 AND m.WarehouseId = p.TransitWarehouseId
                                GROUP BY m.ItemId, m.WarehouseId) x
                   CROSS APPLY (SELECT Q = ISNULL(SUM(s.QuantityBase), 0) FROM inventory.StockMovements s
                                WHERE s.ItemId = x.ItemId AND s.WarehouseId = x.WarehouseId) oh
                   INNER JOIN inventory.Items i       ON i.Id = x.ItemId
                   INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
                   WHERE p.Kind = N'Dispatch' AND p.Status = 2 AND x.Qty > oh.Q
                   ORDER BY i.ItemCode) a5
) x;

GO

