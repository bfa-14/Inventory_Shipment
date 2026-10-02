/* ================================================================== 9. CreateBatch: for an invoice of the order */

-- Re-created (43) from the body of script 28: + @ForInvoiceId (default NULL = as before), passed to usp_Container_Save.
CREATE   PROCEDURE logistics.usp_Container_CreateBatch
    @PurchaseOrderId     INT,
    @ContainerTypeId     INT,
    @OrderDate           DATE           = NULL,   -- NULL = today
    @BranchId            INT            = NULL,   -- NULL = the order's branch
    @WarehouseId         INT            = NULL,   -- NULL = the order's warehouse (offloading destination)
    @ShippingMethod      NVARCHAR(10)   = N'Sea',
    @CountryOfOrigin     NCHAR(2)       = NULL,
    @ForwarderId         INT            = NULL,
    @ShippingLine        NVARCHAR(100)  = NULL,
    @PortOfLoadingId     INT            = NULL,
    @PortOfDestinationId INT            = NULL,
    @FinalDestinationId  INT            = NULL,
    @Eta                 DATE           = NULL,
    @FreeDays            INT            = NULL,
    @Plan                logistics.tvp_ContainerPlanLine READONLY,
    @Capacities          logistics.tvp_ItemCapacity READONLY,     -- the same values as for the proposal
    @AllowOverCapacity   BIT            = 0,
    @Confirm             BIT            = 0,                      -- 1 = the new containers are confirmed at once
    @UserId              INT            = NULL,
    @ForInvoiceId        INT            = NULL                    -- (43) for this invoice: its pieces outside containers at most
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @OrderDate IS NULL SET @OrderDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @OrderBranch INT, @OrderWarehouse INT, @OrderNo NVARCHAR(30);
    SELECT @OrderBranch = d.BranchId, @OrderWarehouse = d.WarehouseId, @OrderNo = d.DocumentNumber
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE d.Id = @PurchaseOrderId AND dt.Code = N'PO' AND (d.Status = 2 OR (d.Status = 4 AND purchase.fn_PurchaseInvoice_TakesContainers(d.Id, @ForInvoiceId) = 1));
    IF @OrderBranch IS NULL THROW 69000, 'The purchase order must be approved and still open.', 1;
    SET @BranchId = ISNULL(@BranchId, @OrderBranch);
    SET @WarehouseId = ISNULL(@WarehouseId, @OrderWarehouse);

    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId AND IsActive = 1)
        THROW 69000, 'Container type not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Plan) THROW 69009, 'The plan has no container to create.', 1;
    IF EXISTS (SELECT 1 FROM @Plan WHERE Seq < 1 OR QuantityBase <= 0)
        THROW 69000, 'Every planned quantity must be greater than zero.', 1;
    IF (SELECT COUNT(DISTINCT Seq) FROM @Plan) > 200
        THROW 69000, 'At most 200 containers can be created at once.', 1;
    IF EXISTS (SELECT 1 FROM @Capacities WHERE PcsPerContainer <= 0)
        THROW 69000, 'Pieces per container must be greater than zero.', 1;

    DECLARE @Msg NVARCHAR(400);
    IF EXISTS (SELECT 1 FROM @Plan p LEFT JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId
               WHERE pol.Id IS NULL OR pol.DocumentId <> @PurchaseOrderId)
    BEGIN
        SET @Msg = N'A planned line is not a line of order ' + ISNULL(@OrderNo, N'(draft)') + N'. Propose the plan again.';
        THROW 69000, @Msg, 1;
    END

    -- pieces per container of every item, as in the proposal
    DECLARE @TypeCap INT = (SELECT MaxUnits FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId);
    DECLARE @Caps TABLE (ItemId INT NOT NULL PRIMARY KEY, Cap INT NULL);
    INSERT INTO @Caps (ItemId, Cap)
    SELECT x.ItemId, COALESCE(cap.PcsPerContainer, NULLIF(cnt.PackingFormula, 0), @TypeCap)
    FROM (SELECT DISTINCT pol.ItemId
          FROM @Plan p INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId) x
    LEFT JOIN @Capacities cap ON cap.ItemId = x.ItemId
    OUTER APPLY (SELECT TOP (1) u.PackingFormula FROM inventory.ItemUnits u
                 INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
                 WHERE u.ItemId = x.ItemId AND t.IsContainer = 1
                 ORDER BY u.Id) cnt;

    -- containers in plan order, each with its equivalent capacity in pieces (NULL = the type's capacity); a container
    -- full within 0.0001 % counts as full, as in usp_Container_PlanFromOrder
    DECLARE @Seqs TABLE (Seq INT NOT NULL PRIMARY KEY, Ord INT NOT NULL, MaxUnits INT NULL);
    INSERT INTO @Seqs (Seq, Ord, MaxUnits)
    SELECT x.Seq, ROW_NUMBER() OVER (ORDER BY x.Seq),
           CASE WHEN x.KnownCaps < x.LineCount THEN NULL
                WHEN x.Fill <= 1.000001 AND FLOOR(x.Units / x.Fill + 0.000001) < x.Units THEN x.Units
                ELSE CAST(FLOOR(x.Units / x.Fill + 0.000001) AS INT) END
    FROM (SELECT p.Seq, LineCount = COUNT(*), KnownCaps = COUNT(c.Cap), Units = SUM(p.QuantityBase),
                 Fill = SUM(CAST(p.QuantityBase AS DECIMAL(38,20)) / c.Cap)
          FROM @Plan p
          INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId
          INNER JOIN @Caps c                            ON c.ItemId = pol.ItemId
          GROUP BY p.Seq) x;

    DECLARE @Created TABLE (Seq INT NOT NULL PRIMARY KEY, ContainerId INT NOT NULL);
    DECLARE @L logistics.tvp_ContainerLoadLine;
    DECLARE @Total INT = (SELECT COUNT(*) FROM @Seqs), @Ord INT = NULL, @Seq INT, @Max INT, @NewId INT, @Lock INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- one plan at a time for an order
        SELECT @Lock = Id FROM purchase.PurchaseDocuments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @PurchaseOrderId;

        -- the whole plan must fit in what the order lines still allow
        SELECT TOP (1) @Msg = N'Order line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                            + CAST(t.Planned AS NVARCHAR(20)) + N' pieces planned but only '
                            + CAST(pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) AS NVARCHAR(20))
                            + N' can still be loaded.'
        FROM (SELECT PoLineId, Planned = SUM(QuantityBase) FROM @Plan GROUP BY PoLineId) t
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = t.PoLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                     INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                     WHERE x.SourceLineId = pol.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2) dir
        OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                     INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                     WHERE cl.PoLineId = pol.Id AND c.Status <> 8) oth
        WHERE t.Planned > pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0)
        ORDER BY pol.LineNumber;
        IF @Msg IS NOT NULL THROW 69008, @Msg, 1;

        -- (43) for an invoice: no more than its pieces of every order line outside containers
        IF @ForInvoiceId IS NOT NULL
        BEGIN
            SELECT TOP (1) @Msg = N'Order line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                + CAST(t.Planned AS NVARCHAR(20)) + N' pieces planned but the invoice has only '
                                + CAST(ISNULL(inv.UnlinkedBase, 0) AS NVARCHAR(20)) + N' outside containers.'
            FROM (SELECT PoLineId, Planned = SUM(QuantityBase) FROM @Plan GROUP BY PoLineId) t
            INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = t.PoLineId
            INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
            LEFT  JOIN purchase.fn_PurchaseInvoice_Unlinked(@ForInvoiceId) inv ON inv.PoLineId = t.PoLineId
            WHERE t.Planned > ISNULL(inv.UnlinkedBase, 0)
            ORDER BY pol.LineNumber;
            IF @Msg IS NOT NULL THROW 69008, @Msg, 1;
        END

        DECLARE plan_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT Seq, Ord, MaxUnits FROM @Seqs ORDER BY Ord;
        OPEN plan_cur;
        FETCH NEXT FROM plan_cur INTO @Seq, @Ord, @Max;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DELETE FROM @L;
            INSERT INTO @L (LineNumber, PoLineId, QuantityBase, OilIncluded, OilQtyPerUnit, Notes)
            SELECT ROW_NUMBER() OVER (ORDER BY pol.LineNumber), p.PoLineId, p.QuantityBase,
                   ISNULL(p.OilIncluded, CASE WHEN i.OilQtyPerUnit > 0 THEN 1 ELSE 0 END), NULL, NULL
            FROM @Plan p
            INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId
            INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
            WHERE p.Seq = @Seq;

            SET @NewId = NULL;
            EXEC logistics.usp_Container_Save
                 @PurchaseOrderId     = @PurchaseOrderId,
                 @ContainerTypeId     = @ContainerTypeId,
                 @OrderDate           = @OrderDate,
                 @ShippingMethod      = @ShippingMethod,
                 @CountryOfOrigin     = @CountryOfOrigin,
                 @ForwarderId         = @ForwarderId,
                 @ShippingLine        = @ShippingLine,
                 @PortOfLoadingId     = @PortOfLoadingId,
                 @PortOfDestinationId = @PortOfDestinationId,
                 @FinalDestinationId  = @FinalDestinationId,
                 @Eta                 = @Eta,
                 @FreeDays            = @FreeDays,
                 @MaxUnits            = @Max,
                 @BranchId            = @BranchId,
                 @WarehouseId         = @WarehouseId,
                 @Lines               = @L,
                 @AllowOverCapacity   = @AllowOverCapacity,
                 @UserId              = @UserId,
                 @ForInvoiceId        = @ForInvoiceId,
                 @NewId               = @NewId OUTPUT;

            IF ISNULL(@Confirm, 0) = 1
                EXEC logistics.usp_Container_Confirm @Id = @NewId, @UserId = @UserId;

            INSERT INTO @Created (Seq, ContainerId) VALUES (@Seq, @NewId);
            FETCH NEXT FROM plan_cur INTO @Seq, @Ord, @Max;
        END
        CLOSE plan_cur;
        DEALLOCATE plan_cur;
        SET @Ord = NULL;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrNo INT = ERROR_NUMBER(), @ErrMsg NVARCHAR(2048) = ERROR_MESSAGE();
        IF @ErrNo >= 50000 AND @Ord IS NOT NULL
        BEGIN
            SET @ErrMsg = LEFT(N'Container ' + CAST(@Seq AS NVARCHAR(10)) + N' of ' + CAST(@Total AS NVARCHAR(10)) + N': ' + @ErrMsg, 2048);
            THROW @ErrNo, @ErrMsg, 1;
        END;
        THROW;
    END CATCH

    SELECT x.Seq, c.Id AS ContainerId, c.ContainerRef, c.Status, c.TotalLines, c.TotalAllocatedBase, c.MaxUnits, c.UtilizationPct,
           c.RowVersion
    FROM @Created x
    INNER JOIN logistics.Containers c ON c.Id = x.ContainerId
    ORDER BY x.Seq;
END

GO

