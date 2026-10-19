/* ================================================================== 5. Cancel: an invoice whose goods were received */

-- Re-created (65) from the body of script 47 (supplier payments):
--   - DECISION 3: a supplier invoice whose goods were received with goods receipts can be cancelled. It has no stock
--     effect: its lines leave the matches (usp_GoodsReceipt_Rematch of its groups, once it is cancelled) and the goods
--     received against it go back to their cost without it (usp_GoodsReceipt_TrueUpCost, cause PINVCANCEL) - the order
--     price, or another posted invoice of the same order line; goods without an order keep the cost they were received
--     at. For an invoice posted after the switch (UsesGoodsReceipts = 1) and an older "Shipped in containers" one.
--   - 69012 only for a container offloaded before goods receipts (fn_Container_ReceivedBy = 'Offload').
--   - An invoice posted with its stock before goods receipts (UsesGoodsReceipts = 0, receipt mode 1): its stock check
--     (65007) and reversal as before, and its order lines' received counter (GoodsReceivedBase) lowered by the pieces of
--     its stock rows, which the switch counted as received.
--   - A purchase order with goods receipts is refused (65011): posted ones are cancelled first, drafts deleted first.
--   - The order reopens when it was closed "Fully received" (before goods receipts) or "Fully invoiced and received".
--   - Audit: + "Cost of received goods adjusted by ..." when the true-up moved something.
--   - A PINV or a PRET takes the goods receipt matching lock FIRST (usp_GoodsReceipt_LockMatching), before the header
--     lock: an invoice rematches and trues up, a return changes what its invoice lines returned.
-- The other refusals stay: posted documents made from it (returns), posted landed cost adjustments, payments allocated.
CREATE   PROCEDURE purchase.usp_PurchaseDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 65000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- (65) lock order: the goods receipt matcher first, then rows, or two postings deadlock. Only a supplier invoice or
        --      a return (their type, read without a lock: it never changes).
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                   WHERE d.Id = @Id AND dt.Code IN (N'PINV', N'PRET'))
            EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @SourceId INT, @Number NVARCHAR(30), @ReceiptMode TINYINT,
                @UsesGoodsReceipts BIT, @SupplierId INT;
        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @SourceId = d.SourceDocumentId,
               @Number = d.DocumentNumber, @ReceiptMode = d.ReceiptMode, @UsesGoodsReceipts = d.UsesGoodsReceipts, @SupplierId = d.SupplierId
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status NOT IN (2, 4) THROW 65010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE SourceDocumentId = @Id AND Status IN (2, 4))
            THROW 65011, 'This document cannot be cancelled: posted documents were created from it. Cancel those first.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE SourceInvoiceId = @Id AND Status = 2)
            THROW 65011, 'This invoice cannot be cancelled: posted landed cost adjustments refer to it. Cancel those first.', 1;
        -- (47) Money paid against it would be left pointing at nothing: the payments are reversed (or de-allocated) first.
        IF EXISTS (SELECT 1 FROM purchase.PaymentAllocations a INNER JOIN purchase.Payments p ON p.Id = a.PaymentId
                   WHERE a.PurchaseDocumentId = @Id AND a.RemovedAtUtc IS NULL AND p.Status = 2)
            THROW 65011, 'This invoice cannot be cancelled: supplier payments are allocated to it. Reverse those payments (or remove the allocations) first.', 1;

        -- (65) RULE 18: goods received against an order would be left without their order. A posted receipt is
        --      cancelled first, a draft deleted first (the order's own receipts, and those of its container lines).
        IF @TypeCode = N'PO'
        BEGIN
            DECLARE @ReceiptStatus TINYINT =
                (SELECT MAX(g.Status) FROM purchase.GoodsReceipts g
                 WHERE g.Status IN (1, 2)
                   AND (g.PurchaseOrderId = @Id
                        OR EXISTS (SELECT 1 FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = g.Id AND gl.PurchaseOrderId = @Id)));
            IF @ReceiptStatus = 2 THROW 65011, 'This purchase order has posted goods receipts. Cancel those first.', 1;
            IF @ReceiptStatus = 1 THROW 65011, 'This purchase order has draft goods receipts. Delete them first.', 1;
        END

        DECLARE @Ct NVARCHAR(400);
        IF @TypeCode = N'PO' AND EXISTS (SELECT 1 FROM logistics.ContainerLines cl INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                                         WHERE cl.PurchaseOrderId = @Id AND c.Status <> 8)
            THROW 65021, 'This purchase order is loaded into containers. Cancel those containers (or remove its lines from them) first.', 1;
        -- (65) Only a container offloaded BEFORE goods receipts received its goods with this invoice (its CNT stock rows were
        --      valued at its lines). A container received with a goods receipt keeps its goods: their cost goes back to
        --      the order price below (decision 3).
        SELECT TOP (1) @Ct = N'This invoice cannot be cancelled: container ' + c.ContainerRef + N' was already offloaded with it. Reverse the offload first.'
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
        INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
        WHERE l.DocumentId = @Id AND c.Status IN (6, 7) AND rb.ReceivedBy = N'Offload'
        ORDER BY c.ContainerRef;
        IF @Ct IS NOT NULL THROW 69012, @Ct, 1;

        -- (65) AN INVOICE POSTED WITH ITS STOCK, BEFORE GOODS RECEIPTS (UsesGoodsReceipts = 0, receipt mode 1): its stock
        --      rows are reversed below, as before. The switch counted those rows as received on the order lines
        --      (GoodsReceivedBase), so the same pieces - read from the ledger, as the switch did - leave that counter.
        DECLARE @OldStock BIT = CASE WHEN @TypeCode = N'PINV' AND @UsesGoodsReceipts = 0 AND @ReceiptMode = 1 THEN 1 ELSE 0 END;
        DECLARE @OldReceived TABLE (PoLineId INT NOT NULL PRIMARY KEY, Qty INT NOT NULL);
        IF @OldStock = 1
            INSERT INTO @OldReceived (PoLineId, Qty)
            SELECT il.SourceLineId, SUM(m.QuantityBase)
            FROM inventory.StockMovements m
            INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = m.DocumentLineId AND il.DocumentId = m.DocumentId
            WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'PINV' AND m.DocumentId = @Id AND m.IsReversal = 0
              AND il.SourceLineId IS NOT NULL
            GROUP BY il.SourceLineId;

        DECLARE @Msg NVARCHAR(400);
        -- (65) the stock check only for an invoice that brought its own stock (an invoice using goods receipts brought none)
        IF @Direction = 1 AND @ReceiptMode = 1 AND @OldStock = 1
        BEGIN
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = @TypeCode AND m.DocumentId = @Id AND m.IsReversal = 0;

        IF @TypeCode = N'PINV'
            UPDATE purchase.PurchaseDocumentLines SET ReceivedQuantityBase = 0 WHERE DocumentId = @Id;

        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            -- (65) the pieces an old invoice received are no longer received (see @OldReceived)
            UPDATE s SET GoodsReceivedBase = s.GoodsReceivedBase - o.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN @OldReceived o ON o.PoLineId = s.Id;

            -- (65) closed as fully invoiced before goods receipts ("Fully received") or since ("Fully invoiced and received")
            IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 4 AND CloseReason IN (N'Fully received', N'Fully invoiced and received'))
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 2, ClosedAtUtc = NULL, ClosedBy = NULL, CloseReason = NULL WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Updated', N'Re-opened: ' + @Number + N' was cancelled', @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        UPDATE purchase.PurchaseDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        -- (65) DECISION 3: GOODS RECEIVED AGAINST THIS INVOICE GO BACK TO THEIR COST WITHOUT IT. Now that it is cancelled
        --      (its lines received nothing, above), the received pieces of its groups - each order line it invoiced, and
        --      the supplier + item of its lines without an order - are matched again without it (usp_GoodsReceipt_Rematch:
        --      to another posted invoice of the line, else unmatched) and brought to their target cost
        --      (usp_GoodsReceipt_TrueUpCost, cause PINVCANCEL): the order price, or another invoice's price; goods without
        --      an order keep the cost they were received at. The part still in stock changes the average cost, the rest
        --      goes to cost of sales. For an invoice posted after the switch (UsesGoodsReceipts = 1) and an older one
        --      "Shipped in containers" (receipt mode 2; one whose container was offloaded the old way was refused, 69012).
        DECLARE @CostAmount DECIMAL(18,2) = 0, @CostInventory DECIMAL(18,2) = 0, @CostCogs DECIMAL(18,2) = 0, @CostLines INT = 0;
        IF @TypeCode = N'PINV' AND (@UsesGoodsReceipts = 1 OR @ReceiptMode = 2)
        BEGIN
            DECLARE @Anchors purchase.tvp_GoodsReceiptAnchor;
            INSERT INTO @Anchors (Kind, PoLineId, SupplierId, ItemId)
            SELECT DISTINCT 'P', l.SourceLineId, NULL, NULL FROM purchase.PurchaseDocumentLines l
            WHERE l.DocumentId = @Id AND l.SourceLineId IS NOT NULL
            UNION
            SELECT DISTINCT 'S', NULL, @SupplierId, l.ItemId FROM purchase.PurchaseDocumentLines l
            WHERE l.DocumentId = @Id AND l.SourceLineId IS NULL;

            EXEC purchase.usp_GoodsReceipt_Rematch @Anchors;

            DECLARE @GroupLines logistics.tvp_IdList;
            INSERT INTO @GroupLines (Id) SELECT GoodsReceiptLineId FROM purchase.fn_GoodsReceipt_GroupLines(@Anchors);
            IF EXISTS (SELECT 1 FROM @GroupLines)
                EXEC purchase.usp_GoodsReceipt_TrueUpCost @GroupLines, N'PINVCANCEL', @Id, @Number, @UserId,
                     @CostAmount OUTPUT, @CostInventory OUTPUT, @CostCogs OUTPUT, @CostLines OUTPUT;

            IF @CostLines > 0
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
                VALUES (@Id, N'Updated', LEFT(N'Cost of received goods adjusted by ' + CAST(@CostAmount AS NVARCHAR(30))
                                             + N' (stock ' + CAST(@CostInventory AS NVARCHAR(30)) + N', cost of sales '
                                             + CAST(@CostCogs AS NVARCHAR(30)) + N'): the invoice was cancelled', 500), @UserId);
        END

        -- A cancelled receipt / return changes the cost history: replay the ledger for the items concerned.
        IF @Direction <> 0
        BEGIN
            DECLARE @ItemId INT;
            DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;
            OPEN items; FETCH NEXT FROM items INTO @ItemId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC inventory.usp_Item_RebuildCosts @ItemId;
                FETCH NEXT FROM items INTO @ItemId;
            END
            CLOSE items; DEALLOCATE items;
        END

        -- containers of an import: the value basis of their charges changed
        DECLARE @Cid INT;
        DECLARE cts CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT cl.ContainerId FROM purchase.PurchaseDocumentLines l
            INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
            WHERE l.DocumentId = @Id;
        OPEN cts;
        FETCH NEXT FROM cts INTO @Cid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Cid, N'Updated', LEFT(N'Purchase invoice ' + ISNULL(@Number, N'') + N' cancelled: ' + @Reason, 500), @UserId);
            FETCH NEXT FROM cts INTO @Cid;
        END
        CLOSE cts;
        DEALLOCATE cts;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

