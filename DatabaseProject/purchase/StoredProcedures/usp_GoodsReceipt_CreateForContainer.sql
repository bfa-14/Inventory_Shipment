/* ================================================================== 5. Receive goods... on a container: only once delivered */

-- Re-created (95) from the body of script 72: + the rule of fn_Container_ReceiveBlock for "Receive goods..." (@Silent =
-- 0); the Delivery hook (@Silent = 1) runs once the Delivery is completed and is unchanged. Nothing else changes.
CREATE   PROCEDURE purchase.usp_GoodsReceipt_CreateForContainer
    @ContainerId  INT,
    @DocumentDate DATE         = NULL,
    @MovementId   INT          = NULL,
    @UserId       INT          = NULL,
    @Silent       BIT          = 0,
    @NewId        INT          = NULL OUTPUT,
    @SkipReason   NVARCHAR(20) = NULL OUTPUT,
    @WarehouseId  INT          = NULL,
    @Lines        purchase.tvp_GoodsReceiptLine READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @NewId = NULL;
    SET @SkipReason = NULL;

    DECLARE @Status TINYINT, @Ref NVARCHAR(30), @BranchId INT, @CtWarehouse INT, @OpenId INT, @OpenNo NVARCHAR(30),
            @OpenStatus TINYINT, @Msg NVARCHAR(400);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @Ref = ContainerRef, @BranchId = BranchId, @CtWarehouse = WarehouseId
        FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @ContainerId;
        IF @Status IS NULL THROW 63006, 'Container not found.', 1;

        SELECT TOP (1) @OpenId = Id, @OpenNo = DocumentNumber, @OpenStatus = Status
        FROM purchase.GoodsReceipts WITH (UPDLOCK, HOLDLOCK)
        WHERE ContainerId = @ContainerId AND Status < 3
        ORDER BY Status DESC, Id DESC;

        SET @SkipReason = CASE WHEN @Status = 8 THEN N'Cancelled'
                               WHEN @Status = 1 THEN N'NotConfirmed'
                               WHEN @Status IN (6, 7) OR @OpenStatus = 2 THEN N'Received'
                               WHEN @OpenStatus = 1 THEN N'HasDraft'
                               WHEN NOT EXISTS (SELECT 1 FROM logistics.ContainerLines WHERE ContainerId = @ContainerId) THEN N'NoLines' END;
        IF @SkipReason IS NOT NULL
        BEGIN
            IF @Silent = 1
            BEGIN
                COMMIT TRANSACTION;
                RETURN;
            END
            IF @OpenId IS NOT NULL
            BEGIN
                SET @Msg = N'Container ' + @Ref + N' already has ' + ISNULL(N'goods receipt ' + @OpenNo, N'a draft goods receipt') + N'. Open it instead.';
                THROW 63013, @Msg, 1;
            END
            IF @SkipReason = N'NoLines'
            BEGIN
                SET @Msg = N'Container ' + @Ref + N' has no lines to receive.';
                THROW 63009, @Msg, 1;
            END;
            THROW 63010, 'Only a confirmed container that is not received yet can be received.', 1;
        END

        -- (95) RECEIVE GOODS... ONLY ONCE DELIVERED: a container that travels with movements is received after its
        -- Delivery is completed (the Delivery drafts it, or Receive goods... after it). One followed by typed dates only
        -- (no movement) keeps the rule of before. The Delivery hook (@Silent = 1) runs after the completion: delivered.
        IF @Silent = 0
        BEGIN
            SET @Msg = (SELECT b.Reason FROM logistics.fn_Container_ReceiveBlock(@ContainerId) b);
            IF @Msg IS NOT NULL THROW 63010, @Msg, 1;
        END

        -- the received pieces given by the dialog: rows of this container's lines, each once, in a unit of the item
        SELECT TOP (1) @Msg = N'Line ' + CAST(r.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN cl.Id IS NULL THEN N'it is not a line of container ' + @Ref + N'.'
                 WHEN iu.Id IS NULL THEN N'the unit does not belong to the item of the container line.'
                 WHEN r.Quantity < 0 THEN N'the received quantity cannot be negative.'
                 ELSE N'the container line is given twice.' END
        FROM @Lines r
        LEFT JOIN logistics.ContainerLines cl ON cl.Id = r.ContainerLineId AND cl.ContainerId = @ContainerId
        LEFT JOIN inventory.ItemUnits iu      ON iu.Id = r.ItemUnitId AND iu.ItemId = cl.ItemId
        WHERE cl.Id IS NULL OR iu.Id IS NULL OR r.Quantity < 0
           OR (SELECT COUNT(*) FROM @Lines d WHERE d.ContainerLineId = r.ContainerLineId) > 1
        ORDER BY r.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        DECLARE @T purchase.tvp_GoodsReceiptLine;
        INSERT INTO @T (LineNumber, ItemId, ItemUnitId, Quantity, PoLineId, ContainerLineId, ExpectedQuantityBase,
                        VarianceReasonCode, VarianceReason, CloseShort, ExpiryDate, Notes)
        SELECT ROW_NUMBER() OVER (ORDER BY cl.LineNumber), cl.ItemId, COALESCE(bu.Id, cl.ItemUnitId),
               CASE WHEN r.ContainerLineId IS NOT NULL THEN r.Quantity * iu.PackingFormula ELSE cl.QuantityBase END,
               cl.PoLineId, cl.Id, cl.QuantityBase, r.VarianceReasonCode, r.VarianceReason, 0,
               COALESCE(r.ExpiryDate, pol.ExpiryDate), r.Notes
        FROM logistics.ContainerLines cl
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
        OUTER APPLY (SELECT TOP (1) u.Id FROM inventory.ItemUnits u WHERE u.ItemId = cl.ItemId AND u.IsBaseUnit = 1 ORDER BY u.Id) bu
        LEFT  JOIN @Lines r                           ON r.ContainerLineId = cl.Id
        LEFT  JOIN inventory.ItemUnits iu             ON iu.Id = r.ItemUnitId
        WHERE cl.ContainerId = @ContainerId;

        -- AN INACTIVE ITEM: Save refuses the draft (rule 12). Silent (the Delivery hook), the container is skipped with its
        -- reason, like the other skips, so the completion goes on; otherwise Save says which line.
        IF @Silent = 1 AND EXISTS (SELECT 1 FROM @T t INNER JOIN inventory.Items i ON i.Id = t.ItemId WHERE i.IsActive = 0)
        BEGIN
            SET @SkipReason = N'InactiveItem';
            COMMIT TRANSACTION;
            RETURN;
        END

        -- "Receive into": the container's warehouse only when it can take the goods (active, of the container's branch, and
        -- (72) at the bottom of the tree, script 70); otherwise the draft is made without one, "to choose", and
        -- usp_GoodsReceipt_CreateForMovement says why
        IF @WarehouseId IS NULL
            SET @WarehouseId = (SELECT w.Id FROM masterdata.Warehouses w WHERE w.Id = @CtWarehouse AND w.IsActive = 1 AND w.BranchId = @BranchId
                                                                          AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1);
        IF @DocumentDate IS NULL
            SET @DocumentDate = COALESCE((SELECT EndDate FROM logistics.Movements WHERE Id = @MovementId), CAST(SYSUTCDATETIME() AS DATE));

        EXEC purchase.usp_GoodsReceipt_Save @SourceKind = N'Container', @ContainerId = @ContainerId, @MovementId = @MovementId,
             @DocumentDate = @DocumentDate, @BranchId = @BranchId, @WarehouseId = @WarehouseId, @Lines = @T,
             @UserId = @UserId, @NewId = @NewId OUTPUT;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

