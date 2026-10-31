-- while they are not invoiced, so they cannot be loaded into containers again: they will never come. Disjoint from the
-- invoiced and received pieces when the close was removed (section 2 settled only what was neither), so they are added
-- to the maximum; once the supplier invoices some of them they count as invoiced instead. Nothing else changes.
-- WHAT AN ORDER LINE HAS COMMITTED OUTSIDE CONTAINERS, in pieces - script 65 uses it in place of the "dir" subquery
-- (invoiced outside containers) wherever the pieces still loadable into containers are worked out:
--   Qty = MAX(invoiced outside containers, received outside containers + on draft receipts outside containers)
--         + (77) given up by a close and not invoiced.
-- A maximum, not a sum: an invoiced piece and a received piece outside containers are the same goods (they are matched).
-- Except the pieces of an invoice that took its goods into stock WHEN IT WAS POSTED, before goods receipts
-- (UsesGoodsReceipts = 0, ReceiptMode 1): they are invoiced AND received, and never matched (usp_GoodsReceipt_Rematch
-- leaves those invoices out), so they count on both sides - otherwise goods received later by a goods receipt for the
-- rest of the same order line would hide behind them in the maximum and could be loaded into a container again.
-- Qty is then: those pieces + MAX(the other invoiced pieces, received by goods receipts + on draft receipts).
--   InvoicedOutsideBase         today's "dir": lines of invoices in status 1, 2 or 4 not shipped in containers
--                               (ReceiptMode <> 2) with no container line; @ExceptDocumentId (NULL = none) leaves out
--                               one invoice, as the callers that check that invoice's own lines do
--   ReceivedOutsideBase         posted goods receipt lines of the order line with no container line, plus the pieces of
--                               the invoices received when they were posted (above)
--   InDraftReceiptsOutsideBase  goods receipt lines of the order line with no container line on draft receipts
-- One row, always (0 when nothing).
CREATE   FUNCTION purchase.fn_PoLine_CommittedOutside (@PoLineId INT, @ExceptDocumentId INT)
RETURNS TABLE
AS
RETURN
    SELECT Qty                        = CASE WHEN inv.Qty >= inv.AtPosting + rcv.Posted + rcv.Drafts THEN inv.Qty
                                             ELSE inv.AtPosting + rcv.Posted + rcv.Drafts END
                                        + gu.GivenUp,
           InvoicedOutsideBase        = inv.Qty,
           ReceivedOutsideBase        = inv.AtPosting + rcv.Posted,
           InDraftReceiptsOutsideBase = rcv.Drafts
    FROM (SELECT Qty       = ISNULL(SUM(x.QuantityBase), 0),
                 AtPosting = ISNULL(SUM(CASE WHEN xd.Status IN (2, 4) AND xd.UsesGoodsReceipts = 0 AND xd.ReceiptMode = 1
                                             THEN x.QuantityBase END), 0)
          FROM purchase.PurchaseDocumentLines x
          INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
          WHERE x.SourceLineId = @PoLineId AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2
            AND (@ExceptDocumentId IS NULL OR xd.Id <> @ExceptDocumentId)) inv
    CROSS JOIN (SELECT Posted = ISNULL(SUM(CASE WHEN g.Status = 2 THEN gl.QuantityBase END), 0),
                       Drafts = ISNULL(SUM(CASE WHEN g.Status = 1 THEN gl.QuantityBase END), 0)
                FROM purchase.GoodsReceiptLines gl
                INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId
                WHERE gl.PoLineId = @PoLineId AND gl.ContainerLineId IS NULL AND g.Status IN (1, 2)) rcv
    -- (77) given up by a close and still not invoiced (as in fn_PoLine_Progress); 0 for every other line
    CROSS JOIN (SELECT GivenUp = ISNULL(MAX(CASE WHEN l.ClosedShortBase <= 0 THEN 0
                                                 WHEN l.ClosedShortBase < l.QuantityBase - l.ReceivedQuantityBase THEN l.ClosedShortBase
                                                 WHEN l.QuantityBase > l.ReceivedQuantityBase THEN l.QuantityBase - l.ReceivedQuantityBase
                                                 ELSE 0 END), 0)
                FROM purchase.PurchaseDocumentLines l WHERE l.Id = @PoLineId) gu;

GO

