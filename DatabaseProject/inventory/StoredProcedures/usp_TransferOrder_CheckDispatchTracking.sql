--      the posting's sentences - errors for the whole dispatch, warnings for @ForLineId (or all). Read only, no lock, no
--      warehouse check (a read, W3): the dispatch checks everything again.
CREATE   PROCEDURE inventory.usp_TransferOrder_CheckDispatchTracking
    @Id        INT,
    @Lines     inventory.tvp_TransferDispatchLine READONLY,
    @Tracking  inventory.tvp_TransferDispatchTracking READONLY,
    @ForLineId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id) THROW 62006, 'Transfer order not found.', 1;

    -- the numbers as the posting keeps them (normalised once)
    DECLARE @T inventory.tvp_TransferDispatchTracking;
    INSERT INTO @T (TransferOrderLineId, RowNumber, BatchNo, SerialNo, ExpiryDate, QuantityBase)
    SELECT TransferOrderLineId, RowNumber,
           CASE WHEN BatchNo IS NOT NULL THEN inventory.fn_TrackingNo_Normalize(BatchNo) END,      -- a call only when there is a number
           CASE WHEN SerialNo IS NOT NULL THEN inventory.fn_TrackingNo_Normalize(SerialNo) END,
           ExpiryDate, QuantityBase
    FROM @Tracking;

    SELECT q.Seq, q.Severity, q.ErrorNumber, q.TransferOrderLineId, q.LineNumber, q.RowNumber, q.Message
    FROM inventory.fn_TransferDispatch_TrackingProblems(@Id, @Lines, @T, @ForLineId) q
    ORDER BY q.Seq, q.LineNumber, q.RowNumber;
END

GO

