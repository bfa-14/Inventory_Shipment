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
    IF @Status <> 6 THROW 69010, 'Only an offloaded container that is not closed can be reversed.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Cannot reverse: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                         + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20))
                         + N' left, but this container brought ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
    FROM (SELECT m.ItemId, m.WarehouseId, Qty = SUM(m.QuantityBase)
          FROM inventory.StockMovements m
          WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0
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
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0;

        UPDATE pl SET ReceivedQuantityBase = pl.ReceivedQuantityBase - x.Qty
        FROM purchase.PurchaseDocumentLines pl
        INNER JOIN (SELECT cl.PurchaseLineId, Qty = SUM(cl.ReceivedQuantityBase)
                    FROM logistics.ContainerLines cl WHERE cl.ContainerId = @Id AND cl.ReceivedQuantityBase > 0
                    GROUP BY cl.PurchaseLineId) x ON x.PurchaseLineId = pl.Id;

        DECLARE @Items TABLE (ItemId INT PRIMARY KEY);
        INSERT INTO @Items (ItemId) SELECT DISTINCT ItemId FROM logistics.ContainerLines WHERE ContainerId = @Id;

        UPDATE logistics.ContainerLines SET ReceivedQuantityBase = NULL, VarianceReason = NULL WHERE ContainerId = @Id;
        DELETE FROM logistics.ContainerEvents WHERE ContainerId = @Id AND EventType = N'Offloaded';

        UPDATE logistics.Containers
        SET OffloadedDate = NULL, OffloadedAtUtc = NULL, OffloadedBy = NULL,
            StatusNote = LEFT(N'Offload reversed: ' + @Reason, 200), UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        EXEC logistics.usp_Container_RefreshStatus @Id;

        DECLARE @ItemId INT;
        DECLARE citems CURSOR LOCAL FAST_FORWARD FOR SELECT ItemId FROM @Items;
        OPEN citems; FETCH NEXT FROM citems INTO @ItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC inventory.usp_Item_RebuildCosts @ItemId;
            FETCH NEXT FROM citems INTO @ItemId;
        END
        CLOSE citems; DEALLOCATE citems;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId) VALUES (@Id, N'OffloadCancelled', @Reason, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

