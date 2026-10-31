/* (93) WHAT IS WRONG WITH THE BATCH, SERIAL AND EXPIRY ROWS OF A DISPATCH (5.3.5.3): one row per problem (Seq, Severity
   Error | Warning, ErrorNumber, TransferOrderLineId, LineNumber, RowNumber, Message). THE ONE SOURCE OF THE DISPATCH
   TRACKING RULES: usp_TransferOrder_CheckDispatchTracking (the dialog's Done) returns every row (warnings only for
   @ForLineId when given, errors for the whole dispatch); usp_TransferOrder_DispatchCore throws the first Error of its
   phase: Seq < 90 before the source lock, Seq 90 (already on the way, 62017) after the serial locks. @Tracking holds
   ALREADY NORMALISED numbers (the caller's table variable, fn_TrackingNo_Normalize). Every branch has a CONSTANT Seq and
   Severity, so a caller's WHERE Seq < 90 / Seq = 90 lets the optimiser drop the other branches (the warnings never run
   at posting). Every message part that can be NULL is wrapped in ISNULL. {x} = a number cut to 50 characters + "...". */
CREATE   FUNCTION inventory.fn_TransferDispatch_TrackingProblems
(
    @OrderId   INT,
    @Lines     inventory.tvp_TransferDispatchLine READONLY,
    @Tracking  inventory.tvp_TransferDispatchTracking READONLY,
    @ForLineId INT
)
RETURNS TABLE
AS
RETURN
WITH hd AS
(
    -- the order: always one row (an aggregate without GROUP BY)
    SELECT No       = ISNULL(MAX(o.DocumentNumber), N'this transfer order'),
           FromId   = MAX(o.FromWarehouseId),
           FromCode = ISNULL(MAX(fw.WarehouseCode), N'')
    FROM inventory.TransferOrders o
    INNER JOIN masterdata.Warehouses fw ON fw.Id = o.FromWarehouseId
    WHERE o.Id = @OrderId
),
ln AS
(
    -- the lines that leave on this dispatch, with the item's kind now
    SELECT LineId = l.Id, l.LineNumber, l.ItemId, i.ItemCode, Q = x.QuantityBase,
           K = CASE i.TrackingMode WHEN 2 THEN 2 WHEN 1 THEN 1 ELSE CASE WHEN i.RequiresExpiry = 1 THEN 3 END END,
           i.RequiresExpiry, i.SerialLength,
           P = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N')'
    FROM @Lines x
    INNER JOIN inventory.TransferOrderLines l ON l.Id = x.TransferOrderLineId AND l.TransferOrderId = @OrderId
    INNER JOIN inventory.Items i              ON i.Id = l.ItemId
    WHERE x.QuantityBase > 0
),
j AS
(
    -- the rows of those lines
    SELECT ln.LineId, ln.LineNumber, ln.ItemId, ln.ItemCode, ln.Q, ln.K, ln.RequiresExpiry, ln.SerialLength, ln.P,
           t.RowNumber, t.SerialNo, t.BatchNo, t.ExpiryDate, t.QuantityBase,
           R    = CAST(t.RowNumber AS NVARCHAR(10)),
           SLen = LEN(t.SerialNo),
           BLen = LEN(t.BatchNo),
           SX   = ISNULL(CASE WHEN LEN(t.SerialNo) > 50 THEN LEFT(t.SerialNo, 50) + NCHAR(8230) ELSE t.SerialNo END, N''),
           BX   = ISNULL(CASE WHEN LEN(t.BatchNo) > 50 THEN LEFT(t.BatchNo, 50) + NCHAR(8230) ELSE t.BatchNo END, N''),
           ExpX = ISNULL(CONVERT(NVARCHAR(10), t.ExpiryDate, 103), N'')
    FROM @Tracking t
    INNER JOIN ln ON ln.LineId = t.TransferOrderLineId
),
sd AS
(
    -- the serials of serial lines, with their duplicates on the line and on the dispatch's other lines of the item
    SELECT j.LineId, j.LineNumber, j.ItemCode, j.P, j.RowNumber, j.SX,
           LineRn  = ROW_NUMBER() OVER (PARTITION BY j.LineId, j.SerialNo ORDER BY j.RowNumber),
           MinLine = MIN(j.LineNumber) OVER (PARTITION BY j.ItemId, j.SerialNo),
           MaxLine = MAX(j.LineNumber) OVER (PARTITION BY j.ItemId, j.SerialNo)
    FROM j
    WHERE j.K = 2 AND j.SerialNo IS NOT NULL
),
bd AS
(
    SELECT j.LineId, j.LineNumber, j.P, j.RowNumber, j.BX,
           Rn = ROW_NUMBER() OVER (PARTITION BY j.LineId, j.BatchNo ORDER BY j.RowNumber)
    FROM j
    WHERE j.K = 1 AND j.BatchNo IS NOT NULL
),
xd AS
(
    SELECT j.LineId, j.LineNumber, j.P, j.RowNumber, j.ExpX,
           Rn = ROW_NUMBER() OVER (PARTITION BY j.LineId, j.ExpiryDate ORDER BY j.RowNumber)
    FROM j
    WHERE j.K = 3 AND j.ExpiryDate IS NOT NULL
)
SELECT Seq                 = CAST(b.Seq AS INT),
       Severity            = CAST(b.Severity AS NVARCHAR(10)),
       ErrorNumber         = CAST(b.ErrorNumber AS INT),
       TransferOrderLineId = CAST(b.LineId AS INT),
       LineNumber          = CAST(b.LineNumber AS INT),
       RowNumber           = CAST(b.RowNumber AS INT),
       Message             = CAST(b.Message AS NVARCHAR(400))
FROM
(
    -- 5. At most 10,000 rows a dispatch (B14)
    SELECT Seq = 5, Severity = N'Error', ErrorNumber = 62016, LineId = CAST(NULL AS INT), LineNumber = CAST(NULL AS INT),
           RowNumber = CAST(NULL AS INT), Message = CAST(N'A dispatch holds at most 10,000 batch, serial or expiry rows.' AS NVARCHAR(400))
    WHERE (SELECT COUNT(*) FROM @Tracking) > 10000

    UNION ALL
    -- 7. A row naming a line that is not on the order
    SELECT 7, N'Error', 62016, t.TransferOrderLineId, NULL, MIN(t.RowNumber),
           N'A batch, serial or expiry row names a line that is not on ' + MAX(hd.No) + N'.'
    FROM @Tracking t
    CROSS JOIN hd
    WHERE NOT EXISTS (SELECT 1 FROM inventory.TransferOrderLines l WHERE l.Id = t.TransferOrderLineId AND l.TransferOrderId = @OrderId)
    GROUP BY t.TransferOrderLineId

    UNION ALL
    -- 8. Rows for a line of the order that does not leave on this dispatch
    SELECT 8, N'Error', 62016, l.Id, l.LineNumber, NULL,
           N'Batches, serial nos. or expiry dates were given for line ' + CAST(l.LineNumber AS NVARCHAR(10))
           + N', which does not leave on this dispatch.'
    FROM inventory.TransferOrderLines l
    WHERE l.TransferOrderId = @OrderId
      AND EXISTS (SELECT 1 FROM @Tracking t WHERE t.TransferOrderLineId = l.Id)
      AND NOT EXISTS (SELECT 1 FROM ln WHERE ln.LineId = l.Id)

    UNION ALL
    -- 10. Rows for a line whose item takes none
    SELECT 10, N'Error', 62016, ln.LineId, ln.LineNumber, NULL,
           ln.P + N': ' + ln.ItemCode + N' takes no batch, serial or expiry details (Item Definition): open Dispatch'
           + NCHAR(8230) + N' again.'
    FROM ln
    WHERE ln.K IS NULL AND EXISTS (SELECT 1 FROM @Tracking t WHERE t.TransferOrderLineId = ln.LineId)

    UNION ALL
    -- 11. Rows of another kind than the item's now (it changed while the dialog was open)
    SELECT 11, N'Error', 62016, ln.LineId, ln.LineNumber, NULL,
           ln.P + N': the rows do not match how ' + ln.ItemCode + N' is tracked now ('
           + CASE ln.K WHEN 1 THEN N'batch numbers' WHEN 2 THEN N'serial numbers' ELSE N'expiry dates' END
           + N'): open Dispatch' + NCHAR(8230) + N' again.'
    FROM ln
    WHERE ln.K IS NOT NULL
      AND EXISTS (SELECT 1 FROM @Tracking t
                  WHERE t.TransferOrderLineId = ln.LineId
                    AND ((ln.K = 2 AND t.BatchNo IS NOT NULL) OR (ln.K = 1 AND t.SerialNo IS NOT NULL)
                         OR (ln.K = 3 AND (t.BatchNo IS NOT NULL OR t.SerialNo IS NOT NULL))))

    UNION ALL
    -- 12. A tracked line that leaves without its rows
    SELECT 12, N'Error', 62016, ln.LineId, ln.LineNumber, NULL,
           ln.P + CASE ln.K WHEN 2 THEN N': type the serial numbers of the ' + CAST(ln.Q AS NVARCHAR(20)) + N' pcs that leave (Serial nos.'
                                        + NCHAR(8230) + N').'
                            WHEN 1 THEN N': say which batches the ' + CAST(ln.Q AS NVARCHAR(20)) + N' pcs come from (Batches'
                                        + NCHAR(8230) + N').'
                            ELSE N': give the expiry dates of the ' + CAST(ln.Q AS NVARCHAR(20)) + N' pcs (Expiry dates'
                                 + NCHAR(8230) + N').' END
    FROM ln
    WHERE ln.K IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @Tracking t WHERE t.TransferOrderLineId = ln.LineId)

    UNION ALL
    -- 13. The number is missing
    SELECT 13, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N', row ' + j.R + CASE WHEN j.K = 2 THEN N': the serial no. is missing.' ELSE N': the batch no. is missing.' END
    FROM j
    WHERE (j.K = 2 AND j.SerialNo IS NULL) OR (j.K = 1 AND j.BatchNo IS NULL)

    UNION ALL
    -- 14. The expiry date is required (Expiry items, and batch / serial items that require it)
    SELECT 14, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N', row ' + j.R + N': the expiry date is required for ' + j.ItemCode + N'.'
    FROM j
    WHERE j.K IS NOT NULL AND j.RequiresExpiry = 1 AND j.ExpiryDate IS NULL

    UNION ALL
    -- 15. At most 50 characters
    SELECT 15, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + CASE WHEN j.K = 2 THEN N': serial no. ' + j.SX ELSE N': batch no. ' + j.BX END + N' is longer than 50 characters.'
    FROM j
    WHERE (j.K = 2 AND j.SLen > 50) OR (j.K = 1 AND j.BLen > 50)

    UNION ALL
    -- 16. A serial no.: letters, digits, . / - (a tab or a line break inside has its own sentence). The hyphen comes
    --     FIRST in the brackets: "./-]" would be read as a range by LIKE and refuse every hyphen.
    SELECT 16, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N': serial no. ' + j.SX
           + CASE WHEN j.SerialNo COLLATE Latin1_General_BIN LIKE N'%[' + NCHAR(9) + NCHAR(10) + NCHAR(13) + N']%'
                  THEN N' may not hold a tab or a line break: paste a list with Paste list' + NCHAR(8230) + N' instead.'
                  ELSE N' may hold only letters, digits and . / - (no spaces).' END
    FROM j
    WHERE j.K = 2 AND j.SerialNo COLLATE Latin1_General_BIN LIKE N'%[^-A-Z0-9./]%'

    UNION ALL
    -- 17. A batch no.: letters, digits, spaces, . / _ # - (a tab or a line break inside has its own sentence)
    SELECT 17, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N': batch no. ' + j.BX
           + CASE WHEN j.BatchNo COLLATE Latin1_General_BIN LIKE N'%[' + NCHAR(9) + NCHAR(10) + NCHAR(13) + N']%'
                  THEN N' may not hold a tab or a line break: paste a list with Paste list' + NCHAR(8230) + N' instead.'
                  ELSE N' may hold only letters, digits, spaces and . / _ # -.' END
    FROM j
    WHERE j.K = 1 AND j.BatchNo COLLATE Latin1_General_BIN LIKE N'%[^-A-Z0-9 ./_#]%'

    UNION ALL
    -- 18. The item's exact serial no. length
    SELECT 18, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N': serial no. ' + j.SX + N' has ' + CAST(j.SLen AS NVARCHAR(10)) + N' characters; the serial numbers of '
           + j.ItemCode + N' have ' + CAST(j.SerialLength AS NVARCHAR(10)) + N' (Item Definition).'
    FROM j
    WHERE j.K = 2 AND j.SerialNo IS NOT NULL AND j.SerialLength IS NOT NULL AND j.SLen <> j.SerialLength

    UNION ALL
    -- 19. An expiry date between 01/01/2000 and 31/12/2099
    SELECT 19, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N', row ' + j.R + N': ' + j.ExpX + N' is not a valid expiry date.'
    FROM j
    WHERE j.K IS NOT NULL AND (j.ExpiryDate < '20000101' OR j.ExpiryDate > '20991231')

    UNION ALL
    -- 20. The pieces of a row
    SELECT 20, N'Error', 62016, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N', row ' + j.R + CASE WHEN j.K = 2 THEN N': a serial number is one piece.'
                                         ELSE N': the pieces must be a whole number above 0.' END
    FROM j
    WHERE (j.K = 2 AND j.QuantityBase <> 1) OR (j.K IN (1, 3) AND j.QuantityBase <= 0)

    UNION ALL
    -- 21. A serial no. once in a dispatch: twice on one line (the second row named) ...
    SELECT 21, N'Error', 62016, sd.LineId, sd.LineNumber, sd.RowNumber,
           sd.P + N': serial no. ' + sd.SX + N' is typed twice.'
    FROM sd
    WHERE sd.LineRn = 2

    UNION ALL
    -- ... or on two lines of the same item (each line's row named, so each line's dialog shows it)
    SELECT 21, N'Error', 62016, sd.LineId, sd.LineNumber, sd.RowNumber,
           N'Serial no. ' + sd.SX + N' of ' + sd.ItemCode + N' is twice in this dispatch (lines '
           + CAST(sd.MinLine AS NVARCHAR(10)) + N' and ' + CAST(sd.MaxLine AS NVARCHAR(10)) + N').'
    FROM sd
    WHERE sd.LineRn = 1 AND sd.MinLine <> sd.MaxLine

    UNION ALL
    -- 22. One row per batch on a line
    SELECT 22, N'Error', 62016, bd.LineId, bd.LineNumber, bd.RowNumber,
           bd.P + N': batch ' + bd.BX + N' is on two rows: put its pieces on one row.'
    FROM bd
    WHERE bd.Rn = 2

    UNION ALL
    -- 23. One row per expiry date on an Expiry line
    SELECT 23, N'Error', 62016, xd.LineId, xd.LineNumber, xd.RowNumber,
           xd.P + N': expiry ' + xd.ExpX + N' is on two rows: put its pieces on one row.'
    FROM xd
    WHERE xd.Rn = 2

    UNION ALL
    -- 24. The rows add up to the pcs that leave (12 applies when there is no row)
    SELECT 24, N'Error', 62016, ln.LineId, ln.LineNumber, NULL,
           ln.P + CASE ln.K WHEN 2 THEN N': ' + CAST(ln.Q AS NVARCHAR(20)) + N' pcs leave but ' + CAST(c.C AS NVARCHAR(20))
                                        + N' serial numbers are typed.'
                            WHEN 1 THEN N': the batches add up to ' + CAST(c.S AS NVARCHAR(20)) + N' pcs but '
                                        + CAST(ln.Q AS NVARCHAR(20)) + N' pcs leave.'
                            ELSE N': the expiry dates add up to ' + CAST(c.S AS NVARCHAR(20)) + N' pcs but '
                                 + CAST(ln.Q AS NVARCHAR(20)) + N' pcs leave.' END
    FROM ln
    CROSS APPLY (SELECT C = COUNT(*), S = ISNULL(SUM(CAST(t.QuantityBase AS BIGINT)), 0)
                 FROM @Tracking t WHERE t.TransferOrderLineId = ln.LineId) c
    WHERE ln.K IS NOT NULL AND c.C > 0
      AND ((ln.K = 2 AND c.C <> ln.Q) OR (ln.K IN (1, 3) AND c.S <> ln.Q))

    UNION ALL
    -- 90. NEVER ON THE WAY TWICE (B5, 62017): a row of a POSTED dispatch of the same item and serial not settled yet.
    --     The dispatch reads it after the per-item serial lock (5b), so two dispatches never both pass.
    --     THE ROW IS FOUND BY A MAX(Id) THROUGH IX_TransferPostingTracking_ItemSerial, never a TOP (1) ... ORDER BY the
    --     posting's time: per serial, that let the optimiser scan every posted dispatch in PostedAtUtc order (a row-goal
    --     plan), so its cost grew with the number of postings - 10,000 serials took 1.2 s with 45 postings, 17.7 s with
    --     1,045 and 92 s with 5,045 (the MAX: 0.05-0.12 s), under the source and serial locks. The latest by the row's
    --     Id, as fn_TransferSerial_LastEvent reads it; at most one row is ever on the way (Check 6), so the sentence is
    --     the same. The rows and the posting are read by SEEKS (FORCESEEK, 93 tests): estimating thousands of rows per
    --     serial, the optimiser otherwise hashed every posted dispatch for each serial (0.8-1.3 s for 10,000 serials with
    --     17 posted dispatches, growing with them; with the seeks 0.13 s).
    SELECT 90, N'Error', 62017, j.LineId, j.LineNumber, j.RowNumber,
           N'Serial no. ' + j.SX + N' of ' + j.ItemCode + N' is already on the way with ' + w.DispatchNumber + N' ('
           + w.OrderNumber + N': ' + w.FromCode + N' ' + NCHAR(8594) + N' ' + w.ToCode
           + N'): receive it first, or reverse that dispatch.'
    FROM j
    CROSS APPLY (SELECT DispatchNumber = p.DocumentNumber, OrderNumber = ISNULL(o.DocumentNumber, N''),
                        FromCode = ISNULL(fw.WarehouseCode, N''), ToCode = ISNULL(tw.WarehouseCode, N'')
                 FROM (SELECT Id = MAX(x.Id)
                       FROM inventory.TransferPostingTracking x WITH (FORCESEEK)
                       INNER JOIN inventory.TransferPostings px WITH (FORCESEEK) ON px.Id = x.PostingId AND px.Kind = N'Dispatch' AND px.Status = 2
                       WHERE x.ItemId = j.ItemId AND x.SerialNo = j.SerialNo AND x.SerialNo IS NOT NULL
                         AND x.DispatchTrackingId IS NULL AND x.SettledBase < x.QuantityBase) m
                 INNER JOIN inventory.TransferPostingTracking x ON x.Id = m.Id
                 INNER JOIN inventory.TransferPostings p ON p.Id = x.PostingId
                 INNER JOIN inventory.TransferOrders o   ON o.Id = p.TransferOrderId
                 INNER JOIN masterdata.Warehouses fw     ON fw.Id = p.FromWarehouseId
                 INNER JOIN masterdata.Warehouses tw     ON tw.Id = p.ToWarehouseId) w                             -- (93 tests)
    WHERE j.K = 2 AND j.SerialNo IS NOT NULL

    UNION ALL
    -- 100. WARNINGS (Check only; @ForLineId: that line's). A serial last received by a transfer into another warehouse
    SELECT 100, N'Warning', CAST(NULL AS INT), j.LineId, j.LineNumber, j.RowNumber,
           N'Serial no. ' + j.SX + N' was last received into ' + ISNULL(e.ToCode, N'') + N' by ' + ISNULL(e.PostingNumber, N'')
           + N' on ' + ISNULL(CONVERT(NVARCHAR(10), e.PostingDate, 103), N'') + N', not into ' + hd.FromCode
           + N': check it is really here.'
    FROM j
    CROSS JOIN hd
    CROSS APPLY inventory.fn_TransferSerial_LastEvent(j.ItemId, j.SerialNo) e
    WHERE j.K = 2 AND j.SerialNo IS NOT NULL AND j.SLen <= 50 AND e.Event = N'Received' AND e.ToWarehouseId <> hd.FromId
      AND (@ForLineId IS NULL OR j.LineId = @ForLineId)

    UNION ALL
    -- 101. A serial written off as lost by a receipt
    SELECT 101, N'Warning', NULL, j.LineId, j.LineNumber, j.RowNumber,
           N'Serial no. ' + j.SX + N' was written off as lost by ' + ISNULL(e.PostingNumber, N'') + N' on '
           + ISNULL(CONVERT(NVARCHAR(10), e.PostingDate, 103), N'') + N' (' + ISNULL(e.LossReasonName, N'') + N'): dispatch it only if it was found.'
    FROM j
    CROSS APPLY inventory.fn_TransferSerial_LastEvent(j.ItemId, j.SerialNo) e
    WHERE j.K = 2 AND j.SerialNo IS NOT NULL AND j.SLen <= 50 AND e.Event = N'Lost'
      AND (@ForLineId IS NULL OR j.LineId = @ForLineId)

    UNION ALL
    -- 102. An expiry in the past (once per line and date, B13)
    SELECT 102, N'Warning', NULL, j.LineId, j.LineNumber, MIN(j.RowNumber),
           MAX(j.P) + N': expiry ' + MAX(j.ExpX) + N' is in the past.'
    FROM j
    WHERE j.K IS NOT NULL AND j.ExpiryDate < CAST(SYSUTCDATETIME() AS DATE)
      AND (@ForLineId IS NULL OR j.LineId = @ForLineId)
    GROUP BY j.LineId, j.LineNumber, j.ExpiryDate

    UNION ALL
    -- 103. A batch that left before with another expiry (its latest posted dispatch row)
    SELECT 103, N'Warning', NULL, j.LineId, j.LineNumber, j.RowNumber,
           j.P + N': batch ' + j.BX + N' left with expiry ' + ISNULL(CONVERT(NVARCHAR(10), pb.ExpiryDate, 103), N'no expiry')
           + N' on ' + ISNULL(pb.DispatchNumber, N'') + N'; here it is ' + ISNULL(NULLIF(j.ExpX, N''), N'no expiry') + N'.'
    FROM j
    CROSS APPLY (SELECT TOP (1) x.ExpiryDate, DispatchNumber = p.DocumentNumber
                 FROM inventory.TransferPostingTracking x
                 INNER JOIN inventory.TransferPostings p ON p.Id = x.PostingId AND p.Kind = N'Dispatch' AND p.Status = 2
                 WHERE x.BatchNo = j.BatchNo AND x.BatchNo IS NOT NULL AND x.ItemId = j.ItemId AND x.DispatchTrackingId IS NULL
                 ORDER BY p.PostedAtUtc DESC, p.Id DESC) pb
    WHERE j.K = 1 AND j.BatchNo IS NOT NULL AND j.BLen <= 50
      AND (@ForLineId IS NULL OR j.LineId = @ForLineId)
      AND NOT ((pb.ExpiryDate IS NULL AND j.ExpiryDate IS NULL) OR pb.ExpiryDate = j.ExpiryDate)
) b;

GO

