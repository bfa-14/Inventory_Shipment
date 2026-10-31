/* ================================================================== 12. Cancel Offload: offloads of the old kind only */

-- Re-created (65) from the body of script 27: refused (69010) for a container received with a goods receipt; the order
-- lines' received and settled-short counters (GoodsReceivedBase, GoodsShortBase) follow the reversal, and an order
-- closed as fully invoiced and received opens again.
-- Reverses an offload: movements reversed, invoice lines released, charges spread again (not frozen), costs replayed.
-- Refused once a charge changed the item costs after the offload (69018).
CREATE   PROCEDURE logistics.usp_Container_CancelOffload
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 69000, 'A reason is required.', 1;

    DECLARE @Status TINYINT = (SELECT Status FROM logistics.Containers WHERE Id = @Id);
    IF @Status IS NULL THROW 69006, 'Container not found.', 1;

    -- (65) RULE 26: ONLY AN OFFLOAD OF THE OLD KIND (script 27, fn_Container_ReceivedBy = 'Offload') IS REVERSED HERE. A
    -- container received with a goods receipt is un-received by cancelling that receipt (usp_GoodsReceipt_Cancel), which
    -- also re-matches its invoices and trues up the costs; the status check below refuses the rest (2-5, 7, 8).
    DECLARE @Msg NVARCHAR(400);
    SELECT @Msg = N'This container was received with goods receipt ' + r.GoodsReceiptNumber + N': cancel that goods receipt instead.'
    FROM logistics.fn_Container_ReceivedBy(@Id) r
    WHERE r.ReceivedBy = N'GRN';
    IF @Msg IS NOT NULL THROW 69010, @Msg, 1;

    IF @Status <> 6 THROW 69010, 'Only an offloaded container that is not closed can be reversed.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
    IF EXISTS (SELECT 1 FROM inventory.CostAdjustments ca
               INNER JOIN logistics.ContainerCharges ch ON ch.Id = ca.SourceId
               WHERE ca.SourceKind = N'CNTCHARGE' AND ch.ContainerId = @Id)
        THROW 69018, 'Charges were posted or cancelled after the offload and the item costs were adjusted. The offload can no longer be reversed.', 1;

    -- the offload to reverse = the latest one of this container that is not reversed yet
    DECLARE @Tag NVARCHAR(30) =
        (SELECT TOP (1) m.DocumentNumber FROM inventory.StockMovements m
         WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0
           AND NOT EXISTS (SELECT 1 FROM inventory.StockMovements r
                           WHERE r.DocumentFamily = m.DocumentFamily AND r.DocumentTypeCode = m.DocumentTypeCode
                             AND r.DocumentId = m.DocumentId AND r.DocumentNumber = m.DocumentNumber AND r.IsReversal = 1)
         ORDER BY m.Id DESC);

    SELECT TOP (1) @Msg = N'Cannot reverse: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                         + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20))
                         + N' left, but this container brought ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
    FROM (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
          FROM inventory.StockMovements m
          WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0
            AND m.DocumentNumber = @Tag
          GROUP BY m.ItemId, m.WarehouseId) x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
    WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
    ORDER BY i.ItemCode;
    IF @Msg IS NOT NULL THROW 69015, @Msg, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0
          AND m.DocumentNumber = @Tag;

        -- the invoice lines of the container were received only by this offload
        UPDATE pl SET ReceivedQuantityBase = 0
        FROM purchase.PurchaseDocumentLines pl
        INNER JOIN logistics.ContainerLines cl ON cl.Id = pl.ContainerLineId
        WHERE cl.ContainerId = @Id;

        DECLARE @Items TABLE (ItemId INT PRIMARY KEY);
        INSERT INTO @Items (ItemId) SELECT DISTINCT ItemId FROM logistics.ContainerLines WHERE ContainerId = @Id;

        -- (65) THE ORDER LINES NO LONGER COUNT THESE PIECES AS RECEIVED, NOR THE MISSING ONES AS SETTLED: script 65
        -- filled GoodsReceivedBase from the offloads of the old kind (the received pieces of their container lines) and
        -- GoodsShortBase from what they recorded short (loaded - received), before they are cleared below. An order that
        -- closed as fully invoiced and received opens again; one closed "Fully received" (the old wording of fully
        -- invoiced) stays closed - the reversal changes nothing invoiced.
        UPDATE pol
        SET GoodsReceivedBase = pol.GoodsReceivedBase - x.Rec, GoodsShortBase = pol.GoodsShortBase - x.Short
        FROM purchase.PurchaseDocumentLines pol
        INNER JOIN (SELECT PoLineId, Rec = SUM(ReceivedQuantityBase),
                           Short = SUM(CASE WHEN QuantityBase > ReceivedQuantityBase THEN QuantityBase - ReceivedQuantityBase ELSE 0 END)
                    FROM logistics.ContainerLines
                    WHERE ContainerId = @Id AND PoLineId IS NOT NULL AND ReceivedQuantityBase IS NOT NULL
                    GROUP BY PoLineId) x ON x.PoLineId = pol.Id;

        DECLARE @Reopened TABLE (Id INT NOT NULL PRIMARY KEY);
        UPDATE po
        SET Status = 2, ClosedAtUtc = NULL, ClosedBy = NULL, CloseReason = NULL
        OUTPUT inserted.Id INTO @Reopened (Id)
        FROM purchase.PurchaseDocuments po
        WHERE po.Id IN (SELECT PurchaseOrderId FROM logistics.ContainerLines WHERE ContainerId = @Id)
          AND po.Status = 4 AND po.CloseReason = N'Fully invoiced and received'
          AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                      WHERE l.DocumentId = po.Id AND l.GoodsReceivedBase + l.GoodsShortBase < l.QuantityBase);

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT r.Id, N'Updated', LEFT(N'Re-opened: the offload of ' + c.ContainerRef + N' was reversed', 500), @UserId
        FROM @Reopened r CROSS JOIN logistics.Containers c
        WHERE c.Id = @Id;

        UPDATE logistics.ContainerLines
        SET ReceivedQuantityBase = NULL, VarianceReason = NULL, FobCostBase = NULL, LandedCostBase = NULL
        WHERE ContainerId = @Id;

        UPDATE logistics.ContainerCharges SET AppliedAtOffload = 0 WHERE ContainerId = @Id;
        EXEC logistics.usp_Container_ReallocateCharges @Id;

        UPDATE logistics.Containers
        SET OffloadedDate = NULL, OffloadedAtUtc = NULL, OffloadedBy = NULL,
            StatusNote = LEFT(N'Offload reversed: ' + @Reason, 200), UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        EXEC logistics.usp_Container_RefreshStatus @Id;

        DECLARE @ItemId INT;
        DECLARE citems CURSOR LOCAL FAST_FORWARD FOR SELECT ItemId FROM @Items;
        OPEN citems;
        FETCH NEXT FROM citems INTO @ItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC inventory.usp_Item_RebuildCosts @ItemId;
            FETCH NEXT FROM citems INTO @ItemId;
        END
        CLOSE citems;
        DEALLOCATE citems;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'OffloadCancelled', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

