/* ================================================================== 13. Close: every received piece invoiced (Close and Reopen under lock) */

-- (65) WHY AN OFFLOADED CONTAINER CANNOT BE CLOSED YET, IN ONE PLACE: Close refuses with it, and the container page and
-- list show it (CloseBlockedReason), so the Close button says why before the click. At most one row: draft charges
-- first (70010), then rule 20 (69016): the first container line, in line order, whose pieces received by posted goods
-- receipts are not all matched to posted invoices. A container offloaded before goods receipts had its posted invoices
-- before the offload: rule 20 does not apply to it. No row: nothing here blocks it (the status is checked apart).
-- No NULL reaches a SUM (a receipt line nothing is matched to counts 0): a NULL inside the SUM raised warning 8153 ("Null
-- value is eliminated by an aggregate"), which SqlClient joined to the 69016 message the user read.
CREATE   FUNCTION logistics.fn_Container_CloseBlock (@ContainerId INT)
RETURNS TABLE
AS
RETURN
    SELECT TOP (1) b.ErrorNumber, b.Reason
    FROM (SELECT ErrorNumber = 70010, Ord = 0, LineNumber = 0,
                 Reason = CAST(N'The container still has draft charges. Post or delete them before closing it.' AS NVARCHAR(400))
          WHERE EXISTS (SELECT 1 FROM logistics.ContainerCharges ch WHERE ch.ContainerId = @ContainerId AND ch.Status = 1)
          UNION ALL
          SELECT 69016, 1, cl.LineNumber,
                 CAST(N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                      + CAST(x.Received AS NVARCHAR(20)) + N' received but ' + CAST(x.Invoiced AS NVARCHAR(20))
                      + N' invoiced by posted invoices. Post the supplier invoices before closing the container.' AS NVARCHAR(400))
          FROM logistics.ContainerLines cl
          INNER JOIN inventory.Items i ON i.Id = cl.ItemId
          CROSS APPLY (SELECT Received = ISNULL(SUM(ISNULL(gl.QuantityBase, 0)), 0), Invoiced = ISNULL(SUM(mm.Qty), 0)
                       FROM purchase.GoodsReceiptLines gl
                       INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId AND g.Status = 2
                       CROSS APPLY (SELECT Qty = ISNULL(SUM(m.QuantityBase), 0) FROM purchase.GoodsReceiptInvoiceMatches m
                                    WHERE m.GoodsReceiptLineId = gl.Id) mm
                       WHERE gl.ContainerLineId = cl.Id) x
          WHERE cl.ContainerId = @ContainerId AND x.Invoiced < x.Received
            AND EXISTS (SELECT 1 FROM logistics.fn_Container_ReceivedBy(@ContainerId) r WHERE r.ReceivedBy = N'GRN')) b
    ORDER BY b.Ord, b.LineNumber;

GO

