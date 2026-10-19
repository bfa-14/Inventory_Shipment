/* ================================================================== 25. Cancel a goods receipt */

/* THE STOCK GOES BACK OUT, and everything the receipt set is undone. Only a posted receipt, with a reason (63000).
   Refused (fn_GoodsReceipt_CancelCheck): a closed container (63010), a cost adjusted afterwards (63008), stock used
   (63007); and, once the matches are rebuilt without it, when a purchase return took back goods that would be left
   without a receipt (63010: an invoice line ending with returned > received).
     - reversal movements (the copies, negative, IsReversal = 1, dated now) and Status 3;
     - the NEGSTOCK cost of sales of its own posting is reversed: the sold pieces are again without a receipt;
     - a container: its received quantities, variances and costs cleared, its charges no longer frozen and re-spread,
       back to its movement status (for example Cleared), so it can be received again;
     - the matches of its groups rebuilt, and the other receipts of those groups trued up (GRNCANCEL);
     - the order lines' received and settled short reduced; an order closed because it was fully received reopens;
     - the item costs replayed (usp_Item_RebuildCosts).
   The matching lock is taken first (usp_GoodsReceipt_LockMatching): a purchase return or a posting of the same goods
   then either commits before this cancel reads them (63007, 63010) or waits for it. */
CREATE   PROCEDURE purchase.usp_GoodsReceipt_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');

    BEGIN TRY
        BEGIN TRANSACTION;

        -- lock order: the matcher first, then rows, or two postings deadlock (usp_GoodsReceipt_LockMatching)
        EXEC purchase.usp_GoodsReceipt_LockMatching;

        DECLARE @Status TINYINT, @ContainerId INT, @Number NVARCHAR(30), @Ref NVARCHAR(30);
        SELECT @Status = g.Status, @ContainerId = g.ContainerId, @Number = g.DocumentNumber
        FROM purchase.GoodsReceipts g WITH (UPDLOCK, HOLDLOCK)
        WHERE g.Id = @Id;

        IF @Status IS NULL THROW 63006, 'Goods receipt not found.', 1;
        IF @Status <> 2 THROW 63010, 'Only a posted goods receipt can be cancelled.', 1;
        IF @Reason IS NULL THROW 63000, 'A cancellation reason is required.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceipts WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 63004, 'This goods receipt was modified by another user. Reload the page and try again.', 1;

        IF @ContainerId IS NOT NULL
            SELECT @Ref = c.ContainerRef FROM logistics.Containers c WITH (UPDLOCK, HOLDLOCK) WHERE c.Id = @ContainerId;
        DECLARE @Locked INT = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines pol WITH (UPDLOCK, HOLDLOCK)
                               WHERE pol.Id IN (SELECT gl.PoLineId FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = @Id));

        DECLARE @Err INT, @Msg NVARCHAR(400);
        SELECT TOP (1) @Err = ErrorNumber, @Msg = Message FROM purchase.fn_GoodsReceipt_CancelCheck(@Id) ORDER BY Seq;
        IF @Err IS NOT NULL
        BEGIN
            SET @Msg = ISNULL(@Msg, N'This goods receipt cannot be cancelled.');
            THROW @Err, @Msg, 1;
        END

        -- what it was matched to (the audit of those invoices) and the groups of its lines
        DECLARE @Invoices TABLE (Id INT NOT NULL PRIMARY KEY);
        INSERT INTO @Invoices (Id)
        SELECT DISTINCT il.DocumentId
        FROM purchase.GoodsReceiptInvoiceMatches m
        INNER JOIN purchase.GoodsReceiptLines gl     ON gl.Id = m.GoodsReceiptLineId AND gl.GoodsReceiptId = @Id
        INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = m.InvoiceLineId;

        DECLARE @Anchors purchase.tvp_GoodsReceiptAnchor;
        INSERT INTO @Anchors (Kind, PoLineId, SupplierId, ItemId)
        SELECT DISTINCT 'P', gl.PoLineId, NULL, NULL FROM purchase.GoodsReceiptLines gl WHERE gl.GoodsReceiptId = @Id AND gl.PoLineId IS NOT NULL
        UNION
        SELECT DISTINCT 'S', NULL, gl.SupplierId, gl.ItemId FROM purchase.GoodsReceiptLines gl
        WHERE gl.GoodsReceiptId = @Id AND gl.PoLineId IS NULL AND gl.SupplierId IS NOT NULL;

        -- the invoice lines of those groups and what they had received, to tell which ones lose pieces
        DECLARE @GroupInvoiceLines TABLE (LineId INT NOT NULL PRIMARY KEY, ReceivedBefore INT NOT NULL);
        INSERT INTO @GroupInvoiceLines (LineId, ReceivedBefore)
        SELECT il.Id, il.ReceivedQuantityBase
        FROM purchase.PurchaseDocumentLines il
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = il.DocumentId
        INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
        WHERE EXISTS (SELECT 1 FROM @Anchors a
                      WHERE (a.Kind = 'P' AND a.PoLineId = il.SourceLineId)
                         OR (a.Kind = 'S' AND il.SourceLineId IS NULL AND a.SupplierId = d.SupplierId AND a.ItemId = il.ItemId));

        /* ---- stock */
        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'GRN' AND m.DocumentId = @Id AND m.IsReversal = 0;

        UPDATE purchase.GoodsReceipts
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        -- the cost of sales of the negative stock it filled goes back: without this receipt those pieces are again
        -- sold without a receipt (compensating rows, as the GRNCOST rows always are)
        DECLARE @NegBack TABLE (ChangeId INT NOT NULL PRIMARY KEY, LineId INT NOT NULL, Amount DECIMAL(18,2) NOT NULL);
        INSERT INTO purchase.GoodsReceiptCostChanges (GoodsReceiptLineId, CauseKind, CauseId, CauseNumber, ReceivedBase, InStockBase,
                                                      FobBefore, FobAfter, UnitCostBefore, UnitCostAfter, AmountBase, InventoryBase, CogsBase, CreatedBy)
        OUTPUT inserted.Id, inserted.GoodsReceiptLineId, inserted.AmountBase INTO @NegBack (ChangeId, LineId, Amount)
        SELECT cc.GoodsReceiptLineId, N'NEGSTOCK', @Id, @Number, cc.ReceivedBase, 0, NULL, NULL, cc.UnitCostAfter, cc.UnitCostBefore,
               -cc.AmountBase, -cc.InventoryBase, -cc.CogsBase, @UserId
        FROM purchase.GoodsReceiptCostChanges cc
        INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = cc.GoodsReceiptLineId AND gl.GoodsReceiptId = @Id
        WHERE cc.CauseKind = N'NEGSTOCK' AND cc.AmountBase <> 0;

        INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
        SELECT SYSUTCDATETIME(), gl.ItemId, gl.WarehouseId, w.BranchId, N'COGS', n.Amount, N'GRNCOST', n.ChangeId, @Number, NULL, @UserId
        FROM @NegBack n
        INNER JOIN purchase.GoodsReceiptLines gl ON gl.Id = n.LineId
        INNER JOIN masterdata.Warehouses w       ON w.Id = gl.WarehouseId;

        /* ---- the container: back to its movement status, to be received again. BEFORE the rematch: a container still
           Offloaded without a posted receipt reads as offloaded the old way (fn_Container_ReceivedBy), and its invoice
           lines would be left out of the matching. */
        IF @ContainerId IS NOT NULL
        BEGIN
            UPDATE logistics.ContainerLines
            SET ReceivedQuantityBase = NULL, VarianceReason = NULL, FobCostBase = NULL, LandedCostBase = NULL
            WHERE ContainerId = @ContainerId;

            UPDATE logistics.ContainerCharges SET AppliedAtOffload = 0 WHERE ContainerId = @ContainerId;
            EXEC logistics.usp_Container_ReallocateCharges @ContainerId;

            UPDATE logistics.Containers
            SET OffloadedDate = NULL, OffloadedAtUtc = NULL, OffloadedBy = NULL,
                StatusNote = LEFT(N'Goods receipt ' + @Number + N' cancelled: ' + @Reason, 200),
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @ContainerId;

            EXEC logistics.usp_Container_RefreshStatus @ContainerId;

            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@ContainerId, N'OffloadCancelled', LEFT(N'Goods receipt ' + @Number + N' cancelled: ' + @Reason, 500), @UserId);
        END

        /* ---- matches and costs */
        EXEC purchase.usp_GoodsReceipt_Rematch @Anchors;

        SELECT TOP (1) @Msg = N'Purchase return ' + ISNULL(r.DocumentNumber, N'') + N' took back goods of this receipt. Cancel the return first.'
        FROM @GroupInvoiceLines g
        INNER JOIN purchase.PurchaseDocumentLines il ON il.Id = g.LineId
        OUTER APPLY (SELECT TOP (1) rd.DocumentNumber
                     FROM purchase.PurchaseDocumentLines rl
                     INNER JOIN purchase.PurchaseDocuments rd ON rd.Id = rl.DocumentId AND rd.Status IN (2, 4)
                     WHERE rl.SourceLineId = il.Id
                     ORDER BY rd.PostedAtUtc DESC, rd.Id DESC) r
        WHERE il.ReceivedQuantityBase < g.ReceivedBefore AND il.ReturnedQuantityBase > il.ReceivedQuantityBase
        ORDER BY il.Id;
        IF @Msg IS NOT NULL THROW 63010, @Msg, 1;

        DECLARE @Others logistics.tvp_IdList;
        INSERT INTO @Others (Id) SELECT GoodsReceiptLineId FROM purchase.fn_GoodsReceipt_GroupLines(@Anchors);
        IF EXISTS (SELECT 1 FROM @Others)
            EXEC purchase.usp_GoodsReceipt_TrueUpCost @Others, N'GRNCANCEL', @Id, @Number, @UserId;

        /* ---- order lines */
        UPDATE pol
        SET GoodsReceivedBase = pol.GoodsReceivedBase - x.Rec, GoodsShortBase = pol.GoodsShortBase - x.Short
        FROM purchase.PurchaseDocumentLines pol
        INNER JOIN (SELECT PoLineId, Rec = SUM(QuantityBase), Short = SUM(SettledShortBase)
                    FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id AND PoLineId IS NOT NULL GROUP BY PoLineId) x ON x.PoLineId = pol.Id;

        DECLARE @Reopened TABLE (Id INT NOT NULL PRIMARY KEY);
        UPDATE po
        SET Status = 2, ClosedAtUtc = NULL, ClosedBy = NULL, CloseReason = NULL
        OUTPUT inserted.Id INTO @Reopened (Id)
        FROM purchase.PurchaseDocuments po
        WHERE po.Id IN (SELECT PurchaseOrderId FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id AND PurchaseOrderId IS NOT NULL)
          AND po.Status = 4 AND po.CloseReason IN (N'Fully received', N'Fully invoiced and received')
          AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                      WHERE l.DocumentId = po.Id AND l.GoodsReceivedBase + l.GoodsShortBase < l.QuantityBase);

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT r.Id, N'Updated', N'Re-opened: ' + @Number + N' was cancelled', @UserId FROM @Reopened r;

        /* ---- item costs and audits */
        DECLARE @ItemId INT;
        DECLARE items CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT ItemId FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id AND QuantityBase > 0;
        OPEN items;
        FETCH NEXT FROM items INTO @ItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC inventory.usp_Item_RebuildCosts @ItemId;
            FETCH NEXT FROM items INTO @ItemId;
        END
        CLOSE items;
        DEALLOCATE items;

        INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT i.Id, N'Updated', N'Goods receipt ' + @Number + N' cancelled', @UserId FROM @Invoices i;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

