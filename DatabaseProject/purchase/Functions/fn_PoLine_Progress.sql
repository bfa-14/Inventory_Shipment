/* ================================================================== 2b. What a close by hand gave up stays given up */

-- Re-created (77) from the body of script 64: (77) MaxOutsideBase, the posting cap of a local receipt line, leaves out the
-- pieces a close by hand gave up (ClosedShortBase, section 2) while they are not invoiced. Every other piece settled short
-- may still be received if it turns up, as before; and once the supplier invoices given-up pieces they are received like
-- any invoiced piece. Nothing else changes.
-- One row per line of a purchase order (none for another document type). In pieces:
--   OrderedBase          ordered
--   InvoicedBase         invoiced = ReceivedQuantityBase (its old name, its meaning unchanged)
--   GoodsReceivedBase    received; GoodsShortBase settled short (nothing more will come)
--   InContainersBase     loaded in containers not received yet (status 1-5: draft to cleared)
--   InDraftReceiptsBase  on draft goods receipts outside containers
--   ToReceiveBase        what the "Receive goods..." dialogs propose: ordered - received - short - in containers - in drafts
--   MaxOutsideBase       the posting cap of a local receipt line: ordered - received - in containers - (77) given up by a
--                        close and not invoiced. Neither the drafts (the one being posted is one) nor the other pieces
--                        settled short count: pieces recorded short that turn up later can still be received.
--   OutstandingBase      rule 17, for Shortages and the item's "On order": an open order ordered - received - short, a
--                        closed one invoiced - received - short; 0 when cancelled. Never below 0.
-- ON A CLOSED ORDER (4) "ordered" is what was INVOICED in all three, as in OutstandingBase (rule 17). (77) No order is
-- closed any more: the closed branches stay for the old rows only, which section 2 turned back into approved orders.
-- The status of the order is the caller's to check (OrderStatus): this function never refuses.
CREATE   FUNCTION purchase.fn_PoLine_Progress (@PurchaseOrderId INT)
RETURNS TABLE
AS
RETURN
    SELECT PurchaseOrderId     = d.Id,
           PoLineId            = l.Id,
           l.LineNumber, l.ItemId, l.ItemUnitId, l.PackingFormula, l.WarehouseId,
           OrderStatus         = d.Status,
           OrderedBase         = l.QuantityBase,
           InvoicedBase        = l.ReceivedQuantityBase,
           l.GoodsReceivedBase,
           l.GoodsShortBase,
           InContainersBase    = q.InContainers,
           InDraftReceiptsBase = q.InDrafts,
           ToReceiveBase       = CASE WHEN x.ToReceive > 0 THEN x.ToReceive ELSE 0 END,
           MaxOutsideBase      = CASE WHEN x.MaxOutside > 0 THEN x.MaxOutside ELSE 0 END,
           OutstandingBase     = CASE WHEN x.Outstanding > 0 THEN x.Outstanding ELSE 0 END
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt         ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
    INNER JOIN purchase.PurchaseDocumentLines l   ON l.DocumentId = d.Id
    CROSS APPLY (SELECT InContainers = ISNULL((SELECT SUM(cl.QuantityBase)
                                               FROM logistics.ContainerLines cl
                                               INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                                               WHERE cl.PoLineId = l.Id AND c.Status BETWEEN 1 AND 5), 0),
                        InDrafts     = ISNULL((SELECT SUM(gl.QuantityBase)
                                               FROM purchase.GoodsReceiptLines gl
                                               INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId
                                               WHERE gl.PoLineId = l.Id AND gl.ContainerLineId IS NULL AND g.Status = 1), 0)) q
    CROSS APPLY (SELECT Expected = CASE WHEN d.Status = 4 AND l.ReceivedQuantityBase < l.QuantityBase
                                        THEN l.ReceivedQuantityBase ELSE l.QuantityBase END,
                        -- (77) given up by a close and still not invoiced: at most what is not invoiced
                        GivenUp  = CASE WHEN l.ClosedShortBase <= 0 THEN 0
                                        WHEN l.ClosedShortBase < l.QuantityBase - l.ReceivedQuantityBase THEN l.ClosedShortBase
                                        WHEN l.QuantityBase > l.ReceivedQuantityBase THEN l.QuantityBase - l.ReceivedQuantityBase
                                        ELSE 0 END) e
    CROSS APPLY (SELECT ToReceive   = e.Expected - l.GoodsReceivedBase - l.GoodsShortBase - q.InContainers - q.InDrafts,
                        MaxOutside  = e.Expected - l.GoodsReceivedBase - q.InContainers - e.GivenUp,
                        Outstanding = CASE d.Status WHEN 3 THEN 0
                                                    WHEN 4 THEN l.ReceivedQuantityBase - l.GoodsReceivedBase - l.GoodsShortBase
                                                    ELSE l.QuantityBase - l.GoodsReceivedBase - l.GoodsShortBase END) x
    WHERE d.Id = @PurchaseOrderId;

GO

