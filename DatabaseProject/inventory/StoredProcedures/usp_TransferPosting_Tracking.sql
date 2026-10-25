--      list, the Receive dialog with @OnTheWayOnly = 1, the dispatch note, the export) - never by the order's Get (B18).
--      One row per tracking row, by line and row, with its state in words; a dispatch row's receipts (POSTED, oldest
--      first, at most 3 then " and {n} more"; the same for the ones that wrote pieces off) are worked out for the
--      posting's rows in one aggregate.
CREATE   PROCEDURE inventory.usp_TransferPosting_Tracking
    @PostingId    INT,
    @OnTheWayOnly BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Kind NVARCHAR(10), @Status TINYINT;
    SELECT @Kind = Kind, @Status = Status FROM inventory.TransferPostings WHERE Id = @PostingId;
    IF @Kind IS NULL THROW 62006, 'Dispatch or receipt not found.', 1;
    SET @OnTheWayOnly = ISNULL(@OnTheWayOnly, 0);

    -- a dispatch: what its POSTED receipts did with each row
    DECLARE @Rcv TABLE
    (
        DispatchTrackingId INT           NOT NULL PRIMARY KEY,
        Received           INT           NOT NULL,
        Lost               INT           NOT NULL,
        N                  INT           NOT NULL,
        List               NVARCHAR(200) NULL,
        LostN              INT           NOT NULL,
        LostList           NVARCHAR(200) NULL,
        Reasons            NVARCHAR(100) NULL
    );
    IF @Kind = N'Dispatch'
        INSERT INTO @Rcv (DispatchTrackingId, Received, Lost, N, List, LostN, LostList, Reasons)
        SELECT r.DispatchTrackingId, SUM(r.QuantityBase), SUM(r.LostBase), COUNT(*),
               STRING_AGG(CASE WHEN r.Rn <= 3 THEN r.DocumentNumber END, N', ') WITHIN GROUP (ORDER BY r.Rn),
               SUM(CASE WHEN r.LostBase > 0 THEN 1 ELSE 0 END),
               -- the receipts that wrote pieces off, capped like List (a batch received in many parts, each with a loss)
               STRING_AGG(CASE WHEN r.LostBase > 0 AND r.LostRn <= 3 THEN r.DocumentNumber END, N', ') WITHIN GROUP (ORDER BY r.Rn),
               CASE WHEN MIN(r.ReasonName) = MAX(r.ReasonName) THEN MIN(r.ReasonName)
                    ELSE MIN(r.ReasonName) + N', ' + MAX(r.ReasonName) END
        FROM (SELECT x.DispatchTrackingId, x.QuantityBase, x.LostBase, rp.DocumentNumber,
                     ReasonName = CASE WHEN x.LostBase > 0 THEN
                                       CASE rl.LossReasonCode WHEN N'DAMAGED' THEN N'Damaged' WHEN N'MISSING' THEN N'Missing / stolen'
                                                              WHEN N'DISPATCHCOUNT' THEN N'Wrongly counted at dispatch'
                                                              WHEN N'OTHER' THEN N'Other' END END,
                     Rn = ROW_NUMBER() OVER (PARTITION BY x.DispatchTrackingId ORDER BY rp.PostedAtUtc, rp.Id),
                     LostRn = ROW_NUMBER() OVER (PARTITION BY x.DispatchTrackingId, CASE WHEN x.LostBase > 0 THEN 1 ELSE 0 END
                                                 ORDER BY rp.PostedAtUtc, rp.Id)
              FROM inventory.TransferPostingTracking d
              INNER JOIN inventory.TransferPostingTracking x ON x.DispatchTrackingId = d.Id
              INNER JOIN inventory.TransferPostings rp       ON rp.Id = x.PostingId AND rp.Status = 2
              INNER JOIN inventory.TransferPostingLines rl   ON rl.Id = x.PostingLineId
              WHERE d.PostingId = @PostingId) r
        GROUP BY r.DispatchTrackingId;

    SELECT t.Id, t.PostingId, t.PostingLineId, PostingLineNumber = pl.LineNumber, t.ItemId, i.ItemCode, t.RowNumber, t.Kind,
           t.BatchNo, t.SerialNo, t.ExpiryDate, t.QuantityBase, t.LostBase, t.SettledBase,
           OnTheWayBase = CASE WHEN @Kind = N'Dispatch' AND @Status = 2 THEN t.QuantityBase - t.SettledBase ELSE 0 END,
           t.DispatchTrackingId, DispatchNumber = dp.DocumentNumber,
           State = CAST(s.State AS NVARCHAR(20)),
           StateText = CAST(CASE s.State
                                 WHEN N'Reversed'       THEN N'Reversed'
                                 WHEN N'OnTheWay'       THEN N'On the way'
                                 WHEN N'PartlyReceived' THEN STUFF(CONCAT(CASE WHEN ISNULL(rc.Received, 0) > 0 THEN N', ' + CAST(rc.Received AS NVARCHAR(20)) + N' received' END,
                                                                          CASE WHEN ISNULL(rc.Lost, 0) > 0 THEN N', ' + CAST(rc.Lost AS NVARCHAR(20)) + N' written off' END,
                                                                          N', ' + CAST(t.QuantityBase - t.SettledBase AS NVARCHAR(20)) + N' on the way'), 1, 2, N'')
                                 WHEN N'Received'       THEN CASE WHEN t.DispatchTrackingId IS NULL
                                                                  THEN N'Received by ' + ISNULL(rc.List, N'')
                                                                       + CASE WHEN rc.N > 3 THEN N' and ' + CAST(rc.N - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END
                                                                  ELSE N'Received' END
                                 WHEN N'Lost'           THEN CASE WHEN t.DispatchTrackingId IS NULL
                                                                  THEN N'Written off by ' + ISNULL(rc.LostList, N'')
                                                                       + CASE WHEN rc.LostN > 3 THEN N' and ' + CAST(rc.LostN - 3 AS NVARCHAR(10)) + N' more' ELSE N'' END
                                                                       + N' (' + ISNULL(rc.Reasons, N'') + N')'
                                                                  ELSE N'Written off (' + ISNULL(rn.ReasonName, N'') + N')' END
                                 WHEN N'Settled'        THEN CAST(ISNULL(rc.Received, 0) AS NVARCHAR(20)) + N' received, '
                                                             + CAST(ISNULL(rc.Lost, 0) AS NVARCHAR(20)) + N' written off'
                                 WHEN N'PartlyLost'     THEN CAST(t.QuantityBase AS NVARCHAR(20)) + N' received, ' + CAST(t.LostBase AS NVARCHAR(20))
                                                             + N' written off (' + ISNULL(rn.ReasonName, N'') + N')'
                            END AS NVARCHAR(300))
    FROM inventory.TransferPostingTracking t
    INNER JOIN inventory.TransferPostingLines pl  ON pl.Id = t.PostingLineId
    INNER JOIN inventory.Items i                  ON i.Id = t.ItemId
    LEFT  JOIN inventory.TransferPostingTracking dt ON dt.Id = t.DispatchTrackingId
    LEFT  JOIN inventory.TransferPostings dp      ON dp.Id = dt.PostingId
    LEFT  JOIN @Rcv rc                            ON rc.DispatchTrackingId = t.Id
    CROSS APPLY (SELECT ReasonName = CASE pl.LossReasonCode WHEN N'DAMAGED' THEN N'Damaged' WHEN N'MISSING' THEN N'Missing / stolen'
                                                           WHEN N'DISPATCHCOUNT' THEN N'Wrongly counted at dispatch'
                                                           WHEN N'OTHER' THEN N'Other' END) rn
    CROSS APPLY (SELECT State = CASE WHEN @Status = 3 THEN N'Reversed'
                                     WHEN t.DispatchTrackingId IS NULL THEN
                                          CASE WHEN t.SettledBase = 0 THEN N'OnTheWay'
                                               WHEN t.SettledBase < t.QuantityBase THEN N'PartlyReceived'
                                               WHEN ISNULL(rc.Lost, 0) = 0 THEN N'Received'
                                               WHEN ISNULL(rc.Received, 0) = 0 THEN N'Lost'
                                               ELSE N'Settled' END
                                     WHEN t.LostBase = 0 THEN N'Received'
                                     WHEN t.QuantityBase = 0 THEN N'Lost'
                                     ELSE N'PartlyLost' END) s
    WHERE t.PostingId = @PostingId
      AND (@OnTheWayOnly = 0 OR (@Kind = N'Dispatch' AND @Status = 2 AND t.QuantityBase > t.SettledBase))
    ORDER BY pl.LineNumber, t.RowNumber;
END

GO

