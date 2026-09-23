/* ================================================================== 10. Containers: offload = stock in */

-- The goods arrive: stock movements at the LANDED cost of the invoice line, moving average updated,
-- the invoice lines are marked received. A received quantity may be lower than the loaded one (short shipment).
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
    IF @Status NOT IN (3, 4, 5) THROW 69010, 'Only a container that has left the supplier can be offloaded.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;

    IF @WarehouseId IS NULL SET @WarehouseId = @CtWarehouse;
    IF @WarehouseId IS NULL THROW 69000, 'The offloading warehouse is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 69000, 'The offloading warehouse is inactive or does not belong to the container branch.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.ContainerLines WHERE ContainerId = @Id)
        THROW 69009, 'The container has no items.', 1;

    DECLARE @Msg NVARCHAR(400);

    -- Every invoice must be posted: the landed cost is only known then.
    SELECT TOP (1) @Msg = N'Invoice ' + d.DocumentNumber + N' is not posted yet. Post it before offloading the container.'
    FROM logistics.ContainerInvoices ci
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = ci.PurchaseDocumentId
    WHERE ci.ContainerId = @Id AND d.Status NOT IN (2, 4)
    ORDER BY d.DocumentNumber;
    IF @Msg IS NOT NULL THROW 69010, @Msg, 1;

    SELECT TOP (1) @Msg =
        CASE WHEN cl.Id IS NULL THEN N'A received line does not belong to this container.'
             WHEN r.ReceivedQuantityBase < 0 THEN N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': the received quantity cannot be negative.'
             WHEN r.ReceivedQuantityBase > cl.QuantityBase THEN N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': received '
                  + CAST(r.ReceivedQuantityBase AS NVARCHAR(20)) + N' but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' were loaded.'
             WHEN r.ReceivedQuantityBase <> cl.QuantityBase AND NULLIF(LTRIM(RTRIM(r.VarianceReason)), N'') IS NULL
                  THEN N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': a reason is required when the received quantity differs from the loaded quantity.'
             END
    FROM @Lines r
    LEFT JOIN logistics.ContainerLines cl ON cl.Id = r.LineId AND cl.ContainerId = @Id
    WHERE cl.Id IS NULL OR r.ReceivedQuantityBase < 0 OR r.ReceivedQuantityBase > cl.QuantityBase
       OR (r.ReceivedQuantityBase <> cl.QuantityBase AND NULLIF(LTRIM(RTRIM(r.VarianceReason)), N'') IS NULL)
    ORDER BY cl.LineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE cl
        SET ReceivedQuantityBase = ISNULL(r.ReceivedQuantityBase, cl.QuantityBase),
            VarianceReason = NULLIF(LTRIM(RTRIM(r.VarianceReason)), N'')
        FROM logistics.ContainerLines cl
        LEFT JOIN @Lines r ON r.LineId = cl.Id
        WHERE cl.ContainerId = @Id;

        -- What really entered stock, with the cost frozen on the invoice line.
        DECLARE @Rec TABLE (LineId INT, ItemId INT, SupplierId INT, QuantityBase INT,
                            UnitCostBase DECIMAL(18,6), FobCostBase DECIMAL(18,6), ExpiryDate DATE);
        INSERT INTO @Rec (LineId, ItemId, SupplierId, QuantityBase, UnitCostBase, FobCostBase, ExpiryDate)
        SELECT cl.Id, cl.ItemId, d.SupplierId, cl.ReceivedQuantityBase,
               ISNULL(pl.UnitCostBase, 0), pl.FobCostBase, pl.ExpiryDate
        FROM logistics.ContainerLines cl
        INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = cl.PurchaseLineId
        INNER JOIN purchase.PurchaseDocuments d      ON d.Id = cl.PurchaseDocumentId
        WHERE cl.ContainerId = @Id AND cl.ReceivedQuantityBase > 0;

        -- Moving average per supplier (last supplier / last cost follow the supplier of the goods).
        DECLARE @SupplierId INT;
        DECLARE @R inventory.tvp_ItemReceipt;
        DECLARE suppliers CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT SupplierId FROM @Rec;
        OPEN suppliers; FETCH NEXT FROM suppliers INTO @SupplierId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DELETE FROM @R;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT ItemId, QuantityBase, UnitCostBase, FobCostBase FROM @Rec WHERE SupplierId = @SupplierId;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId, 1;
            FETCH NEXT FROM suppliers INTO @SupplierId;
        END
        CLOSE suppliers; DEALLOCATE suppliers;

        DECLARE @MovementDate DATETIME2(3) =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@OffloadedDate AS DATETIME2(3)));

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
        SELECT @MovementDate, r.ItemId, @WarehouseId, @BranchId, r.QuantityBase, r.UnitCostBase,
               N'Purchase', N'CNT', @Id, r.LineId, @Ref, NULL, r.ExpiryDate, @UserId
        FROM @Rec r;

        -- The invoice lines are received for what actually arrived.
        UPDATE pl SET ReceivedQuantityBase = pl.ReceivedQuantityBase + x.Qty
        FROM purchase.PurchaseDocumentLines pl
        INNER JOIN (SELECT cl.PurchaseLineId, Qty = SUM(cl.ReceivedQuantityBase)
                    FROM logistics.ContainerLines cl WHERE cl.ContainerId = @Id AND cl.ReceivedQuantityBase > 0
                    GROUP BY cl.PurchaseLineId) x ON x.PurchaseLineId = pl.Id;

        UPDATE logistics.Containers
        SET OffloadedDate = @OffloadedDate, OffloadedAtUtc = SYSUTCDATETIME(), OffloadedBy = @UserId,
            WarehouseId = @WarehouseId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO logistics.ContainerEvents (ContainerId, EventType, EventDate, LocationText, Notes, CreatedBy)
        SELECT @Id, N'Offloaded', @OffloadedDate, w.WarehouseName, N'Stock received', @UserId
        FROM masterdata.Warehouses w WHERE w.Id = @WarehouseId;

        EXEC logistics.usp_Container_RefreshStatus @Id;

        DECLARE @Total INT = (SELECT ISNULL(SUM(QuantityBase), 0) FROM @Rec);
        DECLARE @Short INT = (SELECT COUNT(*) FROM logistics.ContainerLines WHERE ContainerId = @Id AND ReceivedQuantityBase < QuantityBase);
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@Id, N'Offloaded', N'Received ' + CAST(@Total AS NVARCHAR(20)) + N' base unit(s) into '
                + (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId)
                + CASE WHEN @Short > 0 THEN N'; ' + CAST(@Short AS NVARCHAR(10)) + N' line(s) short-shipped' ELSE N'' END, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

