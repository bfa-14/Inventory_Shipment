-- refusal above 200 is gone). Still all or nothing, one container after the other, but:
--   - the invoice's rules and the room on the order lines are checked once for the whole plan, under the lock on the
--     order, not again for each container (usp_Container_Save @PlanChecked): a check per container read a total that
--     grew with every container made, so N containers cost N x N;
--   - THE CNT NUMBERS ARE TAKEN AT THE END. Each container is created with a placeholder ref ('~' + session + '-' +
--     its place in the plan) and gets its real number, in plan order, just before the commit: the CNT counter row is
--     locked only for that moment, not for the whole plan (every other Add Container... or Auto-plan in the company
--     waited for it). A plan that fails takes no number at all.
-- The plan's transaction still holds its new containers' rows until it commits: readers that scan the containers
-- (the Containers page, another order's page) wait for it (the database does not use read-committed snapshot).
-- So a plan blocks those readers for as long as it runs. Measured in the sandbox (a database of up to 50,000
-- containers), confirmed at once: 3,000 containers in about 5.5 s, 5,000 in 9.5 s, 10,000 in 18 s (before these two
-- changes: 2,500 took 18 s, 5,000 75 s, 10,000 52 s on a smaller database). The API gives this call a timeout of its own
-- (Database:BatchCommandTimeoutSeconds, 600 s).
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
    @Capacities          logistics.tvp_ItemCapacity READONLY,     -- (54) ignored: the items' Container units only
    @AllowOverCapacity   BIT            = 0,
    @Confirm             BIT            = 0,                      -- 1 = the new containers are confirmed at once
    @UserId              INT            = NULL,
    @ForInvoiceId        INT            = NULL                    -- (43) for this invoice: its pieces outside containers at most
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @OrderDate IS NULL SET @OrderDate = CAST(SYSUTCDATETIME() AS DATE);

    -- (51) containers created for an invoice: the invoice's rules 1-8 first, for the whole plan
    IF @ForInvoiceId IS NOT NULL
    BEGIN
        DECLARE @ForInvoiceQty INT = (SELECT SUM(QuantityBase) FROM @Plan);
        EXEC purchase.usp_PurchaseInvoice_CheckContainers @InvoiceId = @ForInvoiceId, @Action = N'Add', @QuantityBase = @ForInvoiceQty;
    END

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

    DECLARE @Msg NVARCHAR(400);
    IF EXISTS (SELECT 1 FROM @Plan p LEFT JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId
               WHERE pol.Id IS NULL OR pol.DocumentId <> @PurchaseOrderId)
    BEGIN
        SET @Msg = N'A planned line is not a line of order ' + ISNULL(@OrderNo, N'(draft)') + N'. Propose the plan again.';
        THROW 69000, @Msg, 1;
    END

    -- (54) every planned item has a Container unit, as the proposal requires
    SELECT TOP (1) @Msg = N'Line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): set its Container unit in Item Definition first.'
    FROM @Plan p
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId
    INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
    CROSS APPLY logistics.fn_ItemPcsPerContainer(pol.ItemId) cnt
    WHERE cnt.PcsPerContainer IS NULL
    ORDER BY pol.LineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

    -- containers in plan order
    DECLARE @Seqs TABLE (Seq INT NOT NULL PRIMARY KEY, Ord INT NOT NULL);
    INSERT INTO @Seqs (Seq, Ord)
    SELECT x.Seq, ROW_NUMBER() OVER (ORDER BY x.Seq) FROM (SELECT DISTINCT Seq FROM @Plan) x;

    DECLARE @Created TABLE (Seq INT NOT NULL PRIMARY KEY, ContainerId INT NOT NULL, Placeholder NVARCHAR(30) NOT NULL);
    DECLARE @L logistics.tvp_ContainerLoadLine;
    DECLARE @Total INT = (SELECT COUNT(*) FROM @Seqs), @Ord INT = NULL, @Seq INT, @NewId INT, @Lock INT, @Placeholder NVARCHAR(30);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- one plan at a time for an order
        SELECT @Lock = Id FROM purchase.PurchaseDocuments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @PurchaseOrderId;

        -- the whole plan must fit in what the order lines still allow. (65) Committed outside containers = the larger of
        -- invoiced and received (or on draft goods receipts) outside containers.
        SELECT TOP (1) @Msg = N'Order line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                            + CAST(t.Planned AS NVARCHAR(20)) + N' pieces planned but only '
                            + CAST(pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) AS NVARCHAR(20))
                            + N' can still be loaded.'
        FROM (SELECT PoLineId, Planned = SUM(QuantityBase) FROM @Plan GROUP BY PoLineId) t
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = t.PoLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        OUTER APPLY purchase.fn_PoLine_CommittedOutside(pol.Id, NULL) dir
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
            SELECT Seq, Ord FROM @Seqs ORDER BY Ord;
        OPEN plan_cur;
        FETCH NEXT FROM plan_cur INTO @Seq, @Ord;
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
            SET @Placeholder = N'~' + CAST(@@SPID AS NVARCHAR(10)) + N'-' + CAST(@Ord AS NVARCHAR(10));
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
                 @BranchId            = @BranchId,
                 @WarehouseId         = @WarehouseId,
                 @Lines               = @L,
                 @AllowOverCapacity   = @AllowOverCapacity,
                 @UserId              = @UserId,
                 @ForInvoiceId        = @ForInvoiceId,
                 @PlanChecked         = 1,               -- (78) checked above for the whole plan
                 @ContainerRef        = @Placeholder,    -- (78) the real number at the end
                 @NewId               = @NewId OUTPUT;

            IF ISNULL(@Confirm, 0) = 1
                EXEC logistics.usp_Container_Confirm @Id = @NewId, @UserId = @UserId;

            INSERT INTO @Created (Seq, ContainerId, Placeholder) VALUES (@Seq, @NewId, @Placeholder);
            FETCH NEXT FROM plan_cur INTO @Seq, @Ord;
        END
        CLOSE plan_cur;
        DEALLOCATE plan_cur;
        SET @Ord = NULL;

        -- (78) THE REAL NUMBERS, in plan order, now: from here to the commit the CNT counter is locked (one short loop
        -- and two updates), not while the containers were made. The placeholder is replaced in the ref and in the
        -- "Draft ... from order" history row Save wrote.
        DECLARE @Numbers TABLE (Seq INT NOT NULL PRIMARY KEY, ContainerRef NVARCHAR(30) NOT NULL);
        DECLARE @NumSeq INT = (SELECT MIN(Seq) FROM @Created), @Number NVARCHAR(30);
        WHILE @NumSeq IS NOT NULL
        BEGIN
            SET @Number = NULL;
            EXEC inventory.usp_DocumentType_NextNumber N'CNT', @Number OUTPUT, @BranchId;
            INSERT INTO @Numbers (Seq, ContainerRef) VALUES (@NumSeq, @Number);
            SET @NumSeq = (SELECT MIN(Seq) FROM @Created WHERE Seq > @NumSeq);
        END

        UPDATE c SET ContainerRef = n.ContainerRef
        FROM logistics.Containers c
        INNER JOIN @Created x ON x.ContainerId = c.Id
        INNER JOIN @Numbers n ON n.Seq = x.Seq;

        UPDATE a SET Details = REPLACE(a.Details, x.Placeholder, n.ContainerRef)
        FROM logistics.ContainerAudit a
        INNER JOIN @Created x ON x.ContainerId = a.ContainerId
        INNER JOIN @Numbers n ON n.Seq = x.Seq
        WHERE a.Details LIKE N'%~%';

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

    SELECT x.Seq, c.Id AS ContainerId, c.ContainerRef, c.Status, c.TotalLines, c.TotalAllocatedBase,
           fl.FillPct, fl.CapacityKnown, fl.IsOverCapacity,
           c.RowVersion
    FROM @Created x
    INNER JOIN logistics.Containers c ON c.Id = x.ContainerId
    CROSS APPLY logistics.fn_ContainerFill(c.Id) fl
    ORDER BY x.Seq;
END

GO

