/* ================================================================== 12. A completed Delivery: automatic or by hand */

-- Re-created (79) from the body of script 72: when the GRN type's AutoCreateOnDelivery is 0, no draft is made (an
-- empty answer in the same columns). Receive goods... on a container (usp_GoodsReceipt_CreateForContainer) is unchanged.
CREATE   PROCEDURE purchase.usp_GoodsReceipt_CreateForMovement
    @MovementId INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;

    IF @@TRANCOUNT > 0
        THROW 63010, 'The goods receipts of a movement are created after its completion is committed, outside any transaction.', 1;

    DECLARE @Status TINYINT, @Stage NVARCHAR(10), @MovNo NVARCHAR(30), @EndDate DATE;
    SELECT @Status = m.Status, @Stage = mt.Stage, @MovNo = m.MovementNo, @EndDate = m.EndDate
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    WHERE m.Id = @MovementId;
    IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
    IF @Status <> 3 OR @Stage <> N'Delivery' THROW 70010, 'Only a completed Delivery movement creates goods receipts.', 1;

    -- (79) Configuration > Document Types: goods receipts are made by hand. The completion is committed already and
    --      must never fail because of its receipts, so: the same columns, no row (the API says why).
    IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Code = N'GRN' AND AutoCreateOnDelivery = 0)
    BEGIN
        SELECT ContainerId = CAST(NULL AS INT), ContainerRef = CAST(NULL AS NVARCHAR(30)), GoodsReceiptId = CAST(NULL AS INT),
               GoodsReceiptNumber = CAST(NULL AS NVARCHAR(30)), GoodsReceiptStatus = CAST(NULL AS TINYINT),
               WarehouseCode = CAST(NULL AS NVARCHAR(20)), Created = CAST(0 AS BIT), SkipReason = CAST(NULL AS NVARCHAR(20)),
               Message = CAST(NULL AS NVARCHAR(400))
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @Result TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ContainerId INT NOT NULL, ContainerRef NVARCHAR(30) NOT NULL,
                           GoodsReceiptId INT NULL, Created BIT NOT NULL, SkipReason NVARCHAR(20) NULL, Message NVARCHAR(400) NULL);
    DECLARE @Cid INT, @CRef NVARCHAR(30), @NewId INT, @Skip NVARCHAR(20), @Err NVARCHAR(400);

    DECLARE ctn CURSOR LOCAL FAST_FORWARD FOR
        SELECT c.Id, c.ContainerRef
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        WHERE mc.MovementId = @MovementId
        ORDER BY c.ContainerRef;
    OPEN ctn;
    FETCH NEXT FROM ctn INTO @Cid, @CRef;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @NewId = NULL, @Skip = NULL, @Err = NULL;
        BEGIN TRY
            EXEC purchase.usp_GoodsReceipt_CreateForContainer @ContainerId = @Cid, @DocumentDate = @EndDate, @MovementId = @MovementId,
                 @UserId = @UserId, @Silent = 1, @NewId = @NewId OUTPUT, @SkipReason = @Skip OUTPUT;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            SELECT @NewId = NULL, @Skip = N'Error', @Err = LEFT(ERROR_MESSAGE(), 400);
        END CATCH

        INSERT INTO @Result (ContainerId, ContainerRef, GoodsReceiptId, Created, SkipReason, Message)
        VALUES (@Cid, @CRef, COALESCE(@NewId, (SELECT r.GoodsReceiptId FROM logistics.fn_Container_ReceivedBy(@Cid) r)),
                CASE WHEN @NewId IS NOT NULL THEN 1 ELSE 0 END, @Skip, @Err);
        FETCH NEXT FROM ctn INTO @Cid, @CRef;
    END
    CLOSE ctn;
    DEALLOCATE ctn;

    SELECT r.ContainerId, r.ContainerRef, r.GoodsReceiptId, GoodsReceiptNumber = g.DocumentNumber, GoodsReceiptStatus = g.Status,
           WarehouseCode = CASE WHEN r.Created = 1 THEN w.WarehouseCode END, r.Created, r.SkipReason,
           Message = CAST(CASE
               WHEN r.Created = 1 AND w.Id IS NOT NULL THEN N'Draft goods receipt created into ' + w.WarehouseCode + N'.'
               -- (72) the container's warehouse was not taken: say why, rather than leave the reader to guess
               WHEN r.Created = 1 AND cw.Id IS NOT NULL
                   THEN N'Draft goods receipt created: choose the warehouse (' + cw.WarehouseCode + N', the container''s, '
                        + CASE WHEN cw.IsActive = 0 THEN N'is inactive'
                               WHEN cw.BranchId <> c.BranchId THEN N'is not of the container''s branch'
                               ELSE N'has warehouses under it: stock is kept only in the warehouses at the bottom of the tree' END + N').'
               WHEN r.Created = 1 THEN N'Draft goods receipt created: choose the warehouse.'
               WHEN r.SkipReason = N'Error' THEN r.Message
               WHEN r.SkipReason = N'Received' AND g.Status = 2 THEN N'Already received with goods receipt ' + g.DocumentNumber + N'.'
               WHEN r.SkipReason = N'Received' THEN N'Already offloaded.'
               WHEN r.SkipReason = N'HasDraft' THEN N'Already has a draft goods receipt.'
               WHEN r.SkipReason = N'NotConfirmed' THEN N'Not confirmed: confirm the container, then use Receive goods' + NCHAR(8230) + N' on it.'
               WHEN r.SkipReason = N'Cancelled' THEN N'The container is cancelled.'
               WHEN r.SkipReason = N'NoLines' THEN N'The container has no lines.'
               WHEN r.SkipReason = N'InactiveItem'
                   THEN N'Item ' + ISNULL(ia.ItemCode, N'?') + N' is inactive: activate it in Item Definition, then use Receive goods' + NCHAR(8230) + N' on the container.' END
               AS NVARCHAR(400))
    FROM @Result r
    LEFT JOIN purchase.GoodsReceipts g    ON g.Id = r.GoodsReceiptId
    LEFT JOIN masterdata.Warehouses w     ON w.Id = g.WarehouseId
    LEFT JOIN logistics.Containers c      ON c.Id = r.ContainerId
    LEFT JOIN masterdata.Warehouses cw    ON cw.Id = c.WarehouseId
    OUTER APPLY (SELECT TOP (1) i.ItemCode
                 FROM logistics.ContainerLines cl INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 WHERE r.SkipReason = N'InactiveItem' AND cl.ContainerId = r.ContainerId AND i.IsActive = 0
                 ORDER BY cl.LineNumber) ia
    ORDER BY r.Seq;
END

GO

