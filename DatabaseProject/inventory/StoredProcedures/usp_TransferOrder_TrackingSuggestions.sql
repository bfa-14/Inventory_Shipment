--      event (the latest row on a posted posting, by the row's Id, as fn_TransferSerial_LastEvent) is a receipt that
--      received them into the order's From - received into the source by transfers and not sent since - set-based over
--      the item's serials (index ItemSerial), by date received, at most 2,000. Other kinds: no
--      row. Result 1: SerialNo, ExpiryDate, ReceivedByNumber, ReceivedOn. Result 2: the line's TrackingKind now (2 / 1 /
--      3 / NULL), for the answer's trackingKind.
CREATE   PROCEDURE inventory.usp_TransferOrder_TrackingSuggestions
    @Id                  INT,
    @TransferOrderLineId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ItemId INT, @FromId INT, @K TINYINT;
    SELECT @ItemId = l.ItemId, @FromId = o.FromWarehouseId,
           @K = CASE i.TrackingMode WHEN 2 THEN 2 WHEN 1 THEN 1 ELSE CASE WHEN i.RequiresExpiry = 1 THEN 3 END END
    FROM inventory.TransferOrderLines l
    INNER JOIN inventory.TransferOrders o ON o.Id = l.TransferOrderId
    INNER JOIN inventory.Items i          ON i.Id = l.ItemId
    WHERE l.Id = @TransferOrderLineId AND l.TransferOrderId = @Id;
    IF @ItemId IS NULL THROW 62006, 'Transfer order not found.', 1;

    SELECT TOP (2000) x.SerialNo, x.ExpiryDate, ReceivedByNumber = x.DocumentNumber, ReceivedOn = x.PostingDate
    FROM (SELECT t.SerialNo, t.ExpiryDate, t.QuantityBase, t.DispatchTrackingId, p.DocumentNumber, p.PostingDate, p.ToWarehouseId,
                 Rn = ROW_NUMBER() OVER (PARTITION BY t.SerialNo ORDER BY t.Id DESC)
          FROM inventory.TransferPostingTracking t
          INNER JOIN inventory.TransferPostings p ON p.Id = t.PostingId AND p.Status = 2
          WHERE @K = 2 AND t.ItemId = @ItemId AND t.SerialNo IS NOT NULL) x
    WHERE x.Rn = 1 AND x.DispatchTrackingId IS NOT NULL AND x.QuantityBase = 1 AND x.ToWarehouseId = @FromId
    ORDER BY x.PostingDate, x.SerialNo;

    SELECT TrackingKind = @K;
END

GO

