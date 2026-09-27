/* ================================================================== 15. Offload = stock in at the real cost */

-- Needs every line fully invoiced by POSTED invoices and no movement in progress.
-- FOB per unit = the posted invoice lines; the posted charges are spread again over what really arrived and frozen;
-- landed per unit = FOB + charges / quantity received. Stock movements at the landed cost, moving average updated,
-- the invoice lines are received (in posting order) for what arrived.
CREATE   PROCEDURE logistics.usp_Container_Offload
    @Id            INT,
    @Lines         logistics.tvp_ContainerReceipt READONLY,   -- empty = everything received as loaded
    @OffloadedDate DATE      = NULL,
    @WarehouseId   INT       = NULL,                          -- NULL = the container's warehouse
    @RowVersion    BINARY(8) = NULL,
    @UserId        INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @OffloadedDate IS NULL SET @OffloadedDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Status TINYINT, @BranchId INT, @Ref NVARCHAR(30), @CtWarehouse INT;
    SELECT @Status = Status, @BranchId = BranchId, @Ref = ContainerRef, @CtWarehouse = WarehouseId
    FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;

    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status IN (6, 7) THROW 69011, 'This container is already offloaded.', 1;
    IF @Status = 1 THROW 69010, 'Confirm the container before offloading it.', 1;
    IF @Status = 8 THROW 69010, 'A cancelled container cannot be offloaded.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;

    IF @WarehouseId IS NULL SET @WarehouseId = @CtWarehouse;
    IF @WarehouseId IS NULL THROW 69000, 'The offloading warehouse is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 69000, 'The offloading warehouse is inactive or does not belong to the container branch.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.ContainerLines WHERE ContainerId = @Id)
        THROW 69009, 'The container has no items.', 1;

    DECLARE @Msg NVARCHAR(400);

    SELECT TOP (1) @Msg = N'Movement ' + m.MovementNo + N' of this container is still in progress. Complete it before offloading.'
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
    WHERE mc.ContainerId = @Id AND m.Status = 2
    ORDER BY m.MovementNo;
    IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

    SELECT TOP (1) @Msg = N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): ' + CAST(cl.QuantityBase AS NVARCHAR(20))
                          + N' loaded but ' + CAST(ISNULL(q.Posted, 0) AS NVARCHAR(20)) + N' invoiced by posted invoices'
                          + CASE WHEN ISNULL(q.Draft, 0) > 0 THEN N' (' + CAST(q.Draft AS NVARCHAR(20)) + N' in draft invoices)' ELSE N'' END
                          + N'. Every line must be invoiced and the invoices posted before the offload.'
    FROM logistics.ContainerLines cl
    INNER JOIN inventory.Items i ON i.Id = cl.ItemId
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase END),
                        Draft  = SUM(CASE WHEN d.Status = 1 THEN pil.QuantityBase END)
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id) q
    WHERE cl.ContainerId = @Id AND ISNULL(q.Posted, 0) <> cl.QuantityBase
    ORDER BY cl.LineNumber;
    IF @Msg IS NOT NULL THROW 69016, @Msg, 1;

    SELECT TOP (1) @Msg =
        CASE WHEN cl.Id IS NULL THEN N'A received line does not belong to this container.'
             WHEN r.ReceivedQuantityBase < 0 THEN N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': the received quantity cannot be negative.'
             WHEN r.ReceivedQuantityBase > cl.QuantityBase THEN N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': received '
                  + CAST(r.ReceivedQuantityBase AS NVARCHAR(20)) + N' but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' were loaded.'
             ELSE N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': a reason is required when the received quantity differs from the loaded quantity.'
             END
    FROM @Lines r
    LEFT JOIN logistics.ContainerLines cl ON cl.Id = r.LineId AND cl.ContainerId = @Id
    WHERE cl.Id IS NULL OR r.ReceivedQuantityBase < 0 OR r.ReceivedQuantityBase > cl.QuantityBase
       OR (r.ReceivedQuantityBase <> cl.QuantityBase AND NULLIF(LTRIM(RTRIM(r.VarianceReason)), N'') IS NULL)
    ORDER BY cl.LineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

    -- a manual share of a posted charge cannot sit on a line that receives nothing (it could not enter any cost)
    SELECT TOP (1) @Msg = N'The posted charge ' + t.ChargeName + N' has a manual share on line ' + CAST(cl.LineNumber AS NVARCHAR(10))
                          + N' (' + i.ItemCode + N'), which receives nothing. Cancel that charge and enter it again on the received lines.'
    FROM logistics.ContainerChargeAllocations a
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1 AND a.IsManual = 1
    INNER JOIN purchase.ChargeTypes t        ON t.Id = ch.ChargeTypeId
    INNER JOIN logistics.ContainerLines cl   ON cl.Id = a.ContainerLineId
    INNER JOIN inventory.Items i             ON i.Id = cl.ItemId
    LEFT  JOIN @Lines r                      ON r.LineId = cl.Id
    WHERE ch.ContainerId = @Id AND a.AmountBase > 0 AND ISNULL(r.ReceivedQuantityBase, cl.QuantityBase) = 0
    ORDER BY cl.LineNumber;
    IF @Msg IS NOT NULL THROW 70013, @Msg, 1;

    -- every offload has its own number in the ledger (KTG-2026-0001, then KTG-2026-0001/2 after a reversal)
    DECLARE @OffloadNo INT = 1 + (SELECT COUNT(DISTINCT m.DocumentNumber) FROM inventory.StockMovements m
                                  WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0);
    DECLARE @Tag NVARCHAR(30) = LEFT(@Ref + CASE WHEN @OffloadNo > 1 THEN N'/' + CAST(@OffloadNo AS NVARCHAR(10)) ELSE N'' END, 30);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE cl
        SET ReceivedQuantityBase = ISNULL(r.ReceivedQuantityBase, cl.QuantityBase),
            VarianceReason = NULLIF(LTRIM(RTRIM(r.VarianceReason)), N''),
            FobCostBase = f.Fob
        FROM logistics.ContainerLines cl
        LEFT JOIN @Lines r ON r.LineId = cl.Id
        OUTER APPLY (SELECT Fob = SUM(pil.FobCostBase * pil.QuantityBase) / NULLIF(SUM(pil.QuantityBase), 0)
                     FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments d ON d.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND d.Status IN (2, 4)) f
        WHERE cl.ContainerId = @Id;

        -- the posted charges follow the real quantities and values, then they are frozen in the cost of the goods
        EXEC logistics.usp_Container_ReallocateCharges @Id, 0;
        UPDATE logistics.ContainerCharges SET AppliedAtOffload = 1
        WHERE ContainerId = @Id AND Status = 2 AND IncludeInLandedCost = 1;
        EXEC logistics.usp_Container_RecalcCosts @Id;

        DECLARE @Rec TABLE (LineId INT PRIMARY KEY, ItemId INT, SupplierId INT, QuantityBase INT,
                            UnitCostBase DECIMAL(18,6), FobCostBase DECIMAL(18,6), ExpiryDate DATE);
        INSERT INTO @Rec (LineId, ItemId, SupplierId, QuantityBase, UnitCostBase, FobCostBase, ExpiryDate)
        SELECT cl.Id, cl.ItemId, po.SupplierId, cl.ReceivedQuantityBase, ISNULL(cl.LandedCostBase, 0), cl.FobCostBase,
               (SELECT MIN(pil.ExpiryDate) FROM purchase.PurchaseDocumentLines pil
                INNER JOIN purchase.PurchaseDocuments d ON d.Id = pil.DocumentId
                WHERE pil.ContainerLineId = cl.Id AND d.Status IN (2, 4))
        FROM logistics.ContainerLines cl
        INNER JOIN purchase.PurchaseDocuments po ON po.Id = cl.PurchaseOrderId
        WHERE cl.ContainerId = @Id AND cl.ReceivedQuantityBase > 0;

        DECLARE @MovementDate DATETIME2(3) =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@OffloadedDate AS DATETIME2(3)));

        -- per supplier (last supplier / last cost follow the supplier of the goods): moving average first, then the
        -- movements of that supplier, so the next supplier's average sees them
        DECLARE @SupplierId INT;
        DECLARE @R inventory.tvp_ItemReceipt;
        DECLARE suppliers CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT SupplierId FROM @Rec;
        OPEN suppliers;
        FETCH NEXT FROM suppliers INTO @SupplierId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DELETE FROM @R;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT ItemId, QuantityBase, UnitCostBase, FobCostBase FROM @Rec WHERE SupplierId = @SupplierId;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId, 1;

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, r.ItemId, @WarehouseId, @BranchId, r.QuantityBase, r.UnitCostBase,
                   N'Purchase', N'CNT', @Id, r.LineId, @Tag, NULL, r.ExpiryDate, @UserId
            FROM @Rec r
            WHERE r.SupplierId = @SupplierId;

            FETCH NEXT FROM suppliers INTO @SupplierId;
        END
        CLOSE suppliers;
        DEALLOCATE suppliers;

        -- the invoice lines are received, in posting order, for what actually arrived
        WITH x AS
        (
            SELECT pil.Id, pil.QuantityBase, Rec = ISNULL(cl.ReceivedQuantityBase, 0),
                   Before = ISNULL(SUM(pil.QuantityBase) OVER (PARTITION BY cl.Id ORDER BY d.PostedAtUtc, pil.Id
                                                               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
            FROM logistics.ContainerLines cl
            INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
            INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId AND d.Status IN (2, 4)
            WHERE cl.ContainerId = @Id
        )
        UPDATE pl
        SET ReceivedQuantityBase = pl.ReceivedQuantityBase
                                 + CASE WHEN x.Rec - x.Before <= 0 THEN 0
                                        WHEN x.Rec - x.Before >= x.QuantityBase THEN x.QuantityBase
                                        ELSE x.Rec - x.Before END
        FROM purchase.PurchaseDocumentLines pl
        INNER JOIN x ON x.Id = pl.Id;

        UPDATE logistics.Containers
        SET OffloadedDate = @OffloadedDate, OffloadedAtUtc = SYSUTCDATETIME(), OffloadedBy = @UserId,
            WarehouseId = @WarehouseId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        EXEC logistics.usp_Container_RefreshStatus @Id;

        DECLARE @Total INT = (SELECT ISNULL(SUM(QuantityBase), 0) FROM @Rec);
        DECLARE @Short INT = (SELECT COUNT(*) FROM logistics.ContainerLines WHERE ContainerId = @Id AND ReceivedQuantityBase < QuantityBase);
        DECLARE @Value DECIMAL(18,2) = (SELECT ISNULL(SUM(QuantityBase * UnitCostBase), 0) FROM @Rec);
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@Id, N'Offloaded', LEFT(@Tag + N': received ' + CAST(@Total AS NVARCHAR(20)) + N' base unit(s) into '
                + (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId)
                + N' at a landed value of ' + CAST(@Value AS NVARCHAR(30))
                + CASE WHEN @Short > 0 THEN N'; ' + CAST(@Short AS NVARCHAR(10)) + N' line(s) short-shipped' ELSE N'' END, 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

