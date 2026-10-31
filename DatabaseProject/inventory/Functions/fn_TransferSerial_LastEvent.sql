--      posting, by the row's Id (the order the rows were written in; a posting's PostedAtUtc is taken when it starts,
--      so a dispatch that waited on a lock can carry an earlier time than the receipt it follows; the receipt of a
--      "Dispatch and receive" is written after its dispatch): OnTheWay (a dispatch row not settled),
--      Received / Lost (a receipt row), Settled (a dispatch row whose receipt is the later event; never the latest in
--      practice). Read by the warnings only (Check, never the posting): no module but transfers records serials, so it
--      is a clue, never the truth (B5). The latest row is a MAX(Id), never a TOP (1) ... ORDER BY: applied to each of
--      10,000 serials (Check), a TOP (1) let the optimiser pick a row-goal plan (measured 21 s to 399 s; MAX: 1.6 s).
--      The rows and the posting are read by SEEKS (FORCESEEK, 93 tests): estimating thousands of rows per serial, the
--      optimiser otherwise hashed every posted posting for each serial, so a Check of 10,000 serials grew with the
--      postings (37 s with 5,050 postings; with the seeks 0.7-2.0 s).
CREATE   FUNCTION inventory.fn_TransferSerial_LastEvent (@ItemId INT, @SerialNo NVARCHAR(50))
RETURNS TABLE
AS
RETURN
SELECT PostingId       = p.Id,
       PostingKind     = p.Kind,
       PostingNumber   = p.DocumentNumber,
       PostingDate     = p.PostingDate,
       TransferOrderId = p.TransferOrderId,
       OrderNumber     = o.DocumentNumber,
       FromWarehouseId = p.FromWarehouseId,
       FromCode        = fw.WarehouseCode,
       ToWarehouseId   = p.ToWarehouseId,
       ToCode          = tw.WarehouseCode,
       Event           = CAST(CASE WHEN x.DispatchTrackingId IS NULL
                                   THEN CASE WHEN x.SettledBase < x.QuantityBase THEN N'OnTheWay' ELSE N'Settled' END
                                   WHEN x.QuantityBase = 1 THEN N'Received'
                                   WHEN x.LostBase = 1 THEN N'Lost' END AS NVARCHAR(10)),
       LossReasonName  = CAST(CASE WHEN x.DispatchTrackingId IS NOT NULL AND x.LostBase > 0 THEN
                                   CASE pl.LossReasonCode WHEN N'DAMAGED' THEN N'Damaged' WHEN N'MISSING' THEN N'Missing / stolen'
                                                          WHEN N'DISPATCHCOUNT' THEN N'Wrongly counted at dispatch'
                                                          WHEN N'OTHER' THEN N'Other' END END AS NVARCHAR(40))
FROM (SELECT LastId = MAX(lx.Id)
      FROM inventory.TransferPostingTracking lx WITH (FORCESEEK)
      INNER JOIN inventory.TransferPostings lp WITH (FORCESEEK) ON lp.Id = lx.PostingId AND lp.Status = 2
      WHERE lx.ItemId = @ItemId AND lx.SerialNo = @SerialNo AND lx.SerialNo IS NOT NULL) l
INNER JOIN inventory.TransferPostingTracking x ON x.Id = l.LastId
INNER JOIN inventory.TransferPostings p     ON p.Id = x.PostingId
INNER JOIN inventory.TransferPostingLines pl ON pl.Id = x.PostingLineId
INNER JOIN inventory.TransferOrders o       ON o.Id = p.TransferOrderId
INNER JOIN masterdata.Warehouses fw         ON fw.Id = p.FromWarehouseId
INNER JOIN masterdata.Warehouses tw         ON tw.Id = p.ToWarehouseId;

GO

