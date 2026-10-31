--      ReverseDispatch / ReverseReceipt rows of fn_TransferOrder_Blocks): one row per failed rule, the first (lowest
--      Seq) is the reason, none = allowed. Read by usp_TransferPosting_Reverse (thrown as it comes) and by
--      usp_TransferOrder_Get (the posting's ReverseBlockedReason). A RECEIPT BEFORE ITS DISPATCH: a dispatch whose goods
--      a posted receipt took (received or written off) waits for that receipt's reversal; a receipt only while the
--      destination still holds what it brought.
-- Re-created (93) from the body of script 90: + a RECEIPT whose serial (received or lost) is on a row of a POSTED
-- dispatch written after it cannot be reversed (Seq 3, 62013): reversing it would put the serial on the way twice.
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
    -- (93) a receipt whose serial (received or lost) left again with a POSTED dispatch written after it: reversing it
    --      would put the serial on the way twice. Before the stock sentence (Seq 4): the precise reason, even when the
    --      serial left again from the receiving warehouse itself. "After" = the dispatch row's Id is above the receipt
    --      row's, never the postings' PostedAtUtc: a posting takes its time when it STARTS, and a dispatch that waited
    --      on its source lock while this receipt committed would carry an earlier time than the receipt it follows. Its
    --      rows are written only after its on-the-way check (62017), so after this receipt's commit: a higher Id.
    --      PER RECEIPT ROW, THE FIRST LATER DISPATCH ROW (a MIN through IX_TransferPostingTracking_ItemSerial, the posting
    --      by a seek), then the first of those (93 tests): a TOP (1) ... ORDER BY the dispatch row's Id let the optimiser
    --      scan every tracking row in Id order against the receipt's rows (a row-goal plan) - with no serial dispatched
    --      again, the usual case, it read them all: 77-99 s for the Get of an order with a 10,000-serial receipt, which
    --      timed out the answer of Receive and Dispatch and receive after they had posted. The same first row: the
    --      smallest of the per-row smallest Ids.
    SELECT * FROM (SELECT TOP (1) Seq = 3, ErrorNumber = 62013,
                          Message = N'Cannot reverse: serial no. ' + rr.SerialNo + N' of ' + p.DocumentNumber
                                    + N' has been dispatched again with ' + p2.DocumentNumber + N': reverse that dispatch first.'
                   FROM p
                   INNER JOIN inventory.TransferPostingTracking rr ON rr.PostingId = p.Id AND rr.SerialNo IS NOT NULL
                   CROSS APPLY (SELECT Id = MIN(dx.Id)
                                FROM inventory.TransferPostingTracking dx WITH (FORCESEEK)
                                INNER JOIN inventory.TransferPostings px WITH (FORCESEEK) ON px.Id = dx.PostingId AND px.Kind = N'Dispatch' AND px.Status = 2
                                WHERE dx.ItemId = rr.ItemId AND dx.SerialNo = rr.SerialNo AND dx.SerialNo IS NOT NULL
                                  AND dx.DispatchTrackingId IS NULL AND dx.Id > rr.Id) m
                   INNER JOIN inventory.TransferPostingTracking d2 ON d2.Id = m.Id
                   INNER JOIN inventory.TransferPostings p2 ON p2.Id = d2.PostingId
                   WHERE p.Kind = N'Receipt' AND p.Status = 2
                   ORDER BY m.Id, rr.RowNumber) a3

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

