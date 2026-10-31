/* ================================================================== 8. Goods receipt: save */

-- Re-created (72) from the body of script 64: + the warehouse at the bottom of the tree (script 70) - a container's
-- "Receive into" (still of the container's branch), the "Receive into" of the other receipts (the lines' default) and
-- each local line's warehouse. Nothing else changes.
CREATE   PROCEDURE purchase.usp_GoodsReceipt_Save
    @Id                INT            = NULL,
    @SourceKind        NVARCHAR(10)   = NULL,    -- new receipt: Container | Order | Invoice | Manual; NULL = from the ids
    @DocumentDate      DATE           = NULL,    -- date received; NULL = today (UTC)
    @BranchId          INT            = NULL,    -- Manual (else the warehouse's); several orders; ignored otherwise
    @WarehouseId       INT            = NULL,    -- "Receive into": a container's lines, the default of local lines
    @SupplierId        INT            = NULL,    -- Manual: required; otherwise checked against the source
    @ContainerId       INT            = NULL,
    @PurchaseOrderId   INT            = NULL,    -- informative: taken from the lines
    @PurchaseInvoiceId INT            = NULL,
    @SupplierReference NVARCHAR(100)  = NULL,    -- delivery note no.
    @Notes             NVARCHAR(1000) = NULL,
    @Lines             purchase.tvp_GoodsReceiptLine READONLY,
    @RowVersion        BINARY(8)      = NULL,
    @UserId            INT            = NULL,
    @NewId             INT            = NULL OUTPUT,
    @MovementId        INT            = NULL     -- new container receipt: the completed Delivery movement that made it
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SourceKind = NULLIF(LTRIM(RTRIM(@SourceKind)), N'');
    SET @SupplierReference = NULLIF(LTRIM(RTRIM(@SupplierReference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Msg NVARCHAR(400), @TypeId INT, @IsAuto BIT = 0,
            @OldStatus TINYINT, @OldSource NVARCHAR(10), @OldContainer INT, @OldInvoice INT, @OldMovement INT, @OldBranch INT,
            @Ref NVARCHAR(30), @CtStatus TINYINT, @CtBranch INT, @MovNo NVARCHAR(30),
            @InvNo NVARCHAR(30), @InvStatus TINYINT, @InvBranch INT, @InvSupplier INT, @InvOld BIT, @SourceText NVARCHAR(300);

    /* ---------- 1. The receipt and its source */
    IF @Id IS NOT NULL
    BEGIN
        SELECT @OldStatus = Status, @OldSource = SourceKind, @OldContainer = ContainerId, @OldInvoice = PurchaseInvoiceId,
               @OldMovement = MovementId, @OldBranch = BranchId, @IsAuto = IsAuto
        FROM purchase.GoodsReceipts WHERE Id = @Id;
        IF @OldStatus IS NULL THROW 63006, 'Goods receipt not found.', 1;
        IF @OldStatus <> 1 THROW 63005, 'Only a draft goods receipt can be changed or deleted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceipts WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 63004, 'This goods receipt was modified by another user. Reload the page and try again.', 1;
        IF (@SourceKind IS NOT NULL AND @SourceKind <> @OldSource)
           OR (@ContainerId IS NOT NULL AND @ContainerId <> ISNULL(@OldContainer, -1))
           OR (@PurchaseInvoiceId IS NOT NULL AND @PurchaseInvoiceId <> ISNULL(@OldInvoice, -1))
           OR (@MovementId IS NOT NULL AND @MovementId <> ISNULL(@OldMovement, -1))
            THROW 63000, 'The source of a goods receipt cannot be changed: delete the draft and create another one.', 1;
        SELECT @SourceKind = @OldSource, @ContainerId = @OldContainer, @PurchaseInvoiceId = @OldInvoice, @MovementId = @OldMovement;
    END
    ELSE
    BEGIN
        SET @SourceKind = COALESCE(@SourceKind,
                                   CASE WHEN @ContainerId IS NOT NULL THEN N'Container'
                                        WHEN @PurchaseInvoiceId IS NOT NULL THEN N'Invoice'
                                        WHEN @PurchaseOrderId IS NOT NULL OR EXISTS (SELECT 1 FROM @Lines WHERE PoLineId IS NOT NULL) THEN N'Order'
                                        ELSE N'Manual' END);
        IF @SourceKind NOT IN (N'Container', N'Order', N'Invoice', N'Manual')
            THROW 63000, 'The source of a goods receipt is a container, an order, an invoice, or none (Manual).', 1;
        IF @SourceKind = N'Container' AND @ContainerId IS NULL THROW 63000, 'Choose the container.', 1;
        IF @SourceKind = N'Invoice' AND @PurchaseInvoiceId IS NULL THROW 63000, 'Choose the purchase invoice.', 1;
        IF (@SourceKind <> N'Container' AND (@ContainerId IS NOT NULL OR @MovementId IS NOT NULL))
           OR (@SourceKind <> N'Invoice' AND @PurchaseInvoiceId IS NOT NULL)
           OR (@SourceKind = N'Manual' AND @PurchaseOrderId IS NOT NULL)
            THROW 63000, 'A goods receipt has one source: a container, an order, an invoice, or none (Manual).', 1;
        SET @IsAuto = CASE WHEN @MovementId IS NOT NULL THEN 1 ELSE 0 END;
    END

    IF @DocumentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 63000, 'The date received cannot be in the future.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Lines) THROW 63009, 'The goods receipt has no lines.', 1;
    SET @TypeId = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'GRN');   -- an inactive type still takes drafts
    IF @TypeId IS NULL THROW 63010, 'The document type GRN is missing: restart the API so that script 64 creates it.', 1;

    /* ---------- 2. The lines, as given */
    DECLARE @L TABLE
    (
        LineNumber           INT           NOT NULL PRIMARY KEY,
        ItemId               INT           NOT NULL,
        ItemUnitId           INT           NOT NULL,
        Quantity             INT           NOT NULL,
        PackingFormula       INT           NULL,      -- NULL: the unit is not one of the item's
        IsBaseUnit           BIT           NULL,
        QuantityBase         INT           NULL,
        WarehouseId          INT           NULL,
        PoLineId             INT           NULL,
        PurchaseOrderId      INT           NULL,
        InvoiceLineId        INT           NULL,
        ContainerLineId      INT           NULL,
        ExpectedQuantityBase INT           NULL,
        VarianceReasonCode   NVARCHAR(20)  NULL,
        VarianceReason       NVARCHAR(300) NULL,
        CloseShort           BIT           NOT NULL,
        ManualUnitCostBase   DECIMAL(18,6) NULL,
        ExpiryDate           DATE          NULL,
        Notes                NVARCHAR(300) NULL,
        SupplierId           INT           NULL
    );
    INSERT INTO @L (LineNumber, ItemId, ItemUnitId, Quantity, PackingFormula, IsBaseUnit, QuantityBase, WarehouseId, PoLineId,
                    InvoiceLineId, ContainerLineId, ExpectedQuantityBase, VarianceReasonCode, VarianceReason, CloseShort,
                    ManualUnitCostBase, ExpiryDate, Notes)
    SELECT l.LineNumber, l.ItemId, l.ItemUnitId, l.Quantity, iu.PackingFormula, iu.IsBaseUnit,
           CASE WHEN iu.Id IS NOT NULL THEN l.Quantity * iu.PackingFormula END,
           l.WarehouseId, l.PoLineId, l.InvoiceLineId, l.ContainerLineId, l.ExpectedQuantityBase,
           NULLIF(UPPER(LTRIM(RTRIM(l.VarianceReasonCode))), N''), NULLIF(LTRIM(RTRIM(l.VarianceReason)), N''),
           ISNULL(l.CloseShort, 0), l.ManualUnitCostBase, l.ExpiryDate, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
    FROM @Lines l
    LEFT JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId;

    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN i.Id IS NULL THEN N'item not found.'
             WHEN l.PackingFormula IS NULL THEN N'the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN l.Quantity < 0 THEN N'the received quantity cannot be negative.'
             WHEN l.VarianceReasonCode NOT IN (N'SHORT', N'DAMAGED', N'MISSING', N'LOADCOUNT', N'OTHER')
                 THEN N'the reason is Short-shipped (SHORT), Damaged (DAMAGED), Missing (MISSING), Wrongly counted at loading (LOADCOUNT) or Other (OTHER).'
             WHEN l.ManualUnitCostBase < 0 THEN N'the unit cost cannot be negative.'
             WHEN l.ContainerLineId IS NOT NULL AND @SourceKind <> N'Container' THEN N'only the goods receipt of a container has container lines.'
             WHEN l.InvoiceLineId IS NOT NULL AND @SourceKind <> N'Invoice' THEN N'only the goods receipt of an invoice has invoice lines.'
             ELSE N'a goods receipt without an order has no order lines.' END
    FROM @L l
    LEFT JOIN inventory.Items i ON i.Id = l.ItemId
    WHERE i.Id IS NULL OR l.PackingFormula IS NULL OR l.Quantity < 0
       OR (l.VarianceReasonCode IS NOT NULL AND l.VarianceReasonCode NOT IN (N'SHORT', N'DAMAGED', N'MISSING', N'LOADCOUNT', N'OTHER'))
       OR l.ManualUnitCostBase < 0
       OR (l.ContainerLineId IS NOT NULL AND @SourceKind <> N'Container')
       OR (l.InvoiceLineId IS NOT NULL AND @SourceKind <> N'Invoice')
       OR (l.PoLineId IS NOT NULL AND @SourceKind = N'Manual')
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

    /* ---------- 3. By source */
    IF @SourceKind = N'Container'
    BEGIN
        SELECT @Ref = ContainerRef, @CtStatus = Status, @CtBranch = BranchId FROM logistics.Containers WHERE Id = @ContainerId;
        IF @Ref IS NULL THROW 63006, 'Container not found.', 1;
        IF @Id IS NULL AND @CtStatus NOT BETWEEN 2 AND 5
            THROW 63010, 'Only a confirmed container that is not received yet can be received.', 1;
        IF @Id IS NULL AND @MovementId IS NOT NULL
        BEGIN
            SELECT @MovNo = m.MovementNo FROM logistics.Movements m WHERE m.Id = @MovementId;
            IF NOT EXISTS (SELECT 1 FROM logistics.Movements m
                           INNER JOIN masterdata.MovementTypes mt     ON mt.Id = m.MovementTypeId AND mt.Stage = N'Delivery'
                           INNER JOIN logistics.MovementContainers mc ON mc.MovementId = m.Id AND mc.ContainerId = @ContainerId
                           WHERE m.Id = @MovementId AND m.Status = 3)
            BEGIN
                SET @Msg = N'Movement ' + ISNULL(@MovNo, N'#' + CAST(@MovementId AS NVARCHAR(10)))
                         + N' is not a completed Delivery movement of container ' + @Ref + N'.';
                THROW 63010, @Msg, 1;
            END
        END
        IF @MovementId IS NOT NULL AND @MovNo IS NULL SET @MovNo = (SELECT MovementNo FROM logistics.Movements WHERE Id = @MovementId);
        SET @BranchId = @CtBranch;
        IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @CtBranch)
        BEGIN
            SET @Msg = N'The warehouse ' + ISNULL((SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId), N'#' + CAST(@WarehouseId AS NVARCHAR(10)))
                     + N' is inactive or does not belong to the branch of container ' + @Ref + N'.';
            THROW 63000, @Msg, 1;
        END
        -- (72) AT THE BOTTOM OF THE TREE as well (script 70, which asked it of the offloading warehouse): a warehouse with
        --      warehouses under it is a group, not a place that holds stock. It stays in the container's branch, above.
        IF @WarehouseId IS NOT NULL AND masterdata.fn_Warehouse_IsLeaf(@WarehouseId) = 0
        BEGIN
            SET @Msg = N'The warehouse ' + (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId)
                     + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.';
            THROW 63000, @Msg, 1;
        END
        SELECT @Msg = N'The goods cannot be received before ' + d.MovementNo + N' reached ' + d.PlaceName + N' on '
                      + CONVERT(NVARCHAR(10), d.EndDate, 23) + N'.'
        FROM logistics.fn_Container_LastDelivery(@ContainerId) d
        WHERE @DocumentDate < d.EndDate;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        -- the lines are the container's lines, each once, in pieces, never above the loaded pieces
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): ' +
            CASE WHEN cl.Id IS NULL THEN N'it is not a line of container ' + @Ref + N'.'
                 WHEN (SELECT COUNT(*) FROM @L d WHERE d.ContainerLineId = l.ContainerLineId) > 1
                     THEN N'line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' of container ' + @Ref + N' is on this goods receipt twice.'
                 WHEN cl.ItemId <> l.ItemId THEN N'the item differs from the container line.'
                 WHEN l.IsBaseUnit = 0 THEN N'a container line is received in pieces (the base unit).'
                 ELSE N'received ' + CAST(l.QuantityBase AS NVARCHAR(20)) + N' but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' were loaded.' END
        FROM @L l
        INNER JOIN inventory.Items i           ON i.Id = l.ItemId
        LEFT  JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId AND cl.ContainerId = @ContainerId
        WHERE cl.Id IS NULL OR cl.ItemId <> l.ItemId OR l.IsBaseUnit = 0 OR l.QuantityBase > cl.QuantityBase
           OR (SELECT COUNT(*) FROM @L d WHERE d.ContainerLineId = l.ContainerLineId) > 1
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        SELECT TOP (1) @Msg = N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' of container ' + @Ref + N' (' + i.ItemCode
                              + N') is missing: a container is received with all its lines.'
        FROM logistics.ContainerLines cl
        INNER JOIN inventory.Items i ON i.Id = cl.ItemId
        WHERE cl.ContainerId = @ContainerId AND NOT EXISTS (SELECT 1 FROM @L l WHERE l.ContainerLineId = cl.Id)
        ORDER BY cl.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        -- THE ITEM IS ACTIVE (rule 12), as on the lines of the other sources (section 4), with their sentence: a draft
        -- that Post would refuse is not made. (CreateForContainer, silent for a Delivery, skips such a container.)
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): item ' + i.ItemCode + N' is inactive.'
        FROM @L l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        WHERE i.IsActive = 0
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode
                              + N'): choose a reason when the received quantity differs from the loaded quantity.'
        FROM @L l
        INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
        INNER JOIN inventory.Items i           ON i.Id = l.ItemId
        WHERE l.QuantityBase <> cl.QuantityBase AND l.VarianceReasonCode IS NULL
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        -- the links come from the container line: its order line, order and supplier; expected = loaded; one warehouse
        UPDATE l
        SET PoLineId = cl.PoLineId, PurchaseOrderId = cl.PurchaseOrderId, SupplierId = po.SupplierId,
            ExpectedQuantityBase = cl.QuantityBase, WarehouseId = @WarehouseId, CloseShort = 0, ManualUnitCostBase = NULL,
            ExpiryDate = COALESCE(l.ExpiryDate, pol.ExpiryDate)
        FROM @L l
        INNER JOIN logistics.ContainerLines cl        ON cl.Id = l.ContainerLineId
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
        INNER JOIN purchase.PurchaseDocuments po      ON po.Id = cl.PurchaseOrderId;

        SET @SupplierId = CASE WHEN (SELECT COUNT(DISTINCT SupplierId) FROM @L) = 1 THEN (SELECT MIN(SupplierId) FROM @L) END;
        SET @PurchaseOrderId = CASE WHEN (SELECT COUNT(DISTINCT PurchaseOrderId) FROM @L) = 1 THEN (SELECT MIN(PurchaseOrderId) FROM @L) END;
        SET @SourceText = N'Draft from container ' + @Ref
                        + ISNULL(N', created automatically when ' + @MovNo + N' was completed', N'');
    END
    ELSE IF @SourceKind = N'Order'
    BEGIN
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN l.PoLineId IS NULL THEN N'choose a line of a purchase order.'
                 WHEN pol.Id IS NULL OR dt.Id IS NULL THEN N'the order line was not found.'
                 WHEN (SELECT COUNT(*) FROM @L d WHERE d.PoLineId = l.PoLineId) > 1
                     THEN N'line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' of order ' + ISNULL(po.DocumentNumber, N'#' + CAST(po.Id AS NVARCHAR(10)))
                          + N' is on this goods receipt twice.'
                 ELSE N'the item differs from the order line.' END
        FROM @L l
        LEFT JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        LEFT JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId
        LEFT JOIN inventory.DocumentTypes dt         ON dt.Id = po.DocumentTypeId AND dt.Code = N'PO'
        WHERE l.PoLineId IS NULL OR pol.Id IS NULL OR dt.Id IS NULL OR pol.ItemId <> l.ItemId
           OR (SELECT COUNT(*) FROM @L d WHERE d.PoLineId = l.PoLineId) > 1
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        SELECT TOP (1) @Msg = CASE WHEN po.Status = 3 THEN N'The purchase order ' + ISNULL(po.DocumentNumber, N'#' + CAST(po.Id AS NVARCHAR(10))) + N' is cancelled.'
                                   ELSE N'Only an approved order can be received.' END
        FROM @L l
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        INNER JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId
        WHERE po.Status NOT IN (2, 4)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63010, @Msg, 1;

        UPDATE l
        SET PurchaseOrderId = pol.DocumentId, SupplierId = po.SupplierId, ManualUnitCostBase = NULL,
            WarehouseId = COALESCE(l.WarehouseId, @WarehouseId, pol.WarehouseId),
            ExpiryDate = COALESCE(l.ExpiryDate, pol.ExpiryDate)
        FROM @L l
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        INNER JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId;

        IF (SELECT COUNT(DISTINCT SupplierId) FROM @L) > 1
            THROW 63000, 'A goods receipt from purchase orders holds the orders of one supplier.', 1;
        IF @SupplierId IS NOT NULL AND @SupplierId <> (SELECT MIN(SupplierId) FROM @L)
            THROW 63000, 'The supplier must be the supplier of the purchase order.', 1;
        SET @SupplierId = (SELECT MIN(SupplierId) FROM @L);
        SET @PurchaseOrderId = CASE WHEN (SELECT COUNT(DISTINCT PurchaseOrderId) FROM @L) = 1 THEN (SELECT MIN(PurchaseOrderId) FROM @L) END;
        -- numbered in the order's branch; a receipt of several orders keeps the branch given (or the first line's order's)
        SET @BranchId = CASE WHEN @PurchaseOrderId IS NOT NULL THEN (SELECT BranchId FROM purchase.PurchaseDocuments WHERE Id = @PurchaseOrderId)
                             ELSE COALESCE(@BranchId, @OldBranch,
                                           (SELECT TOP (1) po.BranchId FROM @L l INNER JOIN purchase.PurchaseDocuments po ON po.Id = l.PurchaseOrderId
                                            ORDER BY l.LineNumber)) END;
        SET @SourceText = N'Draft from order ' + ISNULL((SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @PurchaseOrderId), N'(several orders)');
    END
    ELSE IF @SourceKind = N'Invoice'
    BEGIN
        SELECT @InvNo = d.DocumentNumber, @InvStatus = d.Status, @InvBranch = d.BranchId, @InvSupplier = d.SupplierId,
               @InvOld = CASE WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 THEN 1 ELSE 0 END
        FROM purchase.PurchaseDocuments d
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
        WHERE d.Id = @PurchaseInvoiceId;
        IF @InvStatus IS NULL THROW 63006, 'Purchase invoice not found.', 1;
        IF @InvStatus = 3 THROW 63010, 'The purchase invoice is cancelled.', 1;
        IF @InvStatus NOT IN (2, 4) THROW 63010, 'Post the invoice first: goods are received against a posted invoice, or from the order.', 1;
        IF @InvOld = 1 THROW 63010, 'Posted before goods receipts: its stock entered when it was posted (or when its container was offloaded).', 1;

        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN pil.Id IS NULL THEN N'choose a line of invoice ' + ISNULL(@InvNo, N'#' + CAST(@PurchaseInvoiceId AS NVARCHAR(10))) + N'.'
                 WHEN pil.ContainerLineId IS NOT NULL
                     THEN N'this invoice line travels in container ' + ISNULL(c.ContainerRef, N'?') + N': it is received with its container.'
                 WHEN (SELECT COUNT(*) FROM @L d WHERE d.InvoiceLineId = l.InvoiceLineId) > 1
                     THEN N'line ' + CAST(pil.LineNumber AS NVARCHAR(10)) + N' of the invoice is on this goods receipt twice.'
                 WHEN pil.ItemId <> l.ItemId THEN N'the item differs from the invoice line.'
                 ELSE N'the order line differs from the invoice line.' END
        FROM @L l
        LEFT JOIN purchase.PurchaseDocumentLines pil ON pil.Id = l.InvoiceLineId AND pil.DocumentId = @PurchaseInvoiceId
        LEFT JOIN logistics.ContainerLines cl        ON cl.Id = pil.ContainerLineId
        LEFT JOIN logistics.Containers c             ON c.Id = cl.ContainerId
        WHERE pil.Id IS NULL OR pil.ContainerLineId IS NOT NULL OR pil.ItemId <> l.ItemId
           OR (SELECT COUNT(*) FROM @L d WHERE d.InvoiceLineId = l.InvoiceLineId) > 1
           OR (l.PoLineId IS NOT NULL AND l.PoLineId <> ISNULL(pil.SourceLineId, -1))
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        UPDATE l
        SET PoLineId = pil.SourceLineId, PurchaseOrderId = pol.DocumentId, SupplierId = @InvSupplier, ManualUnitCostBase = NULL,
            WarehouseId = COALESCE(l.WarehouseId, @WarehouseId, pil.WarehouseId),
            ExpiryDate = COALESCE(l.ExpiryDate, pil.ExpiryDate, pol.ExpiryDate)
        FROM @L l
        INNER JOIN purchase.PurchaseDocumentLines pil ON pil.Id = l.InvoiceLineId
        LEFT  JOIN purchase.PurchaseDocumentLines pol ON pol.Id = pil.SourceLineId;

        IF @SupplierId IS NOT NULL AND @SupplierId <> @InvSupplier
            THROW 63000, 'The supplier must be the supplier of the purchase invoice.', 1;
        SELECT @SupplierId = @InvSupplier, @BranchId = @InvBranch, @PurchaseOrderId = NULL;
        SET @SourceText = N'Draft from invoice ' + ISNULL(@InvNo, N'#' + CAST(@PurchaseInvoiceId AS NVARCHAR(10)));
    END
    ELSE   -- Manual: "Without an order"
    BEGIN
        IF @SupplierId IS NULL THROW 63000, 'Choose the supplier: a goods receipt without an order needs one.', 1;
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsSupplier = 1 AND IsActive = 1)
            THROW 63000, 'Supplier not found, inactive, or not flagged as a supplier.', 1;
        UPDATE l
        SET SupplierId = @SupplierId, ExpectedQuantityBase = NULL, PurchaseOrderId = NULL,
            WarehouseId = COALESCE(l.WarehouseId, @WarehouseId),
            ManualUnitCostBase = COALESCE(l.ManualUnitCostBase, i.LastCost, i.AverageCost)   -- the typed cost; default the item's last cost, else its average (as Post)
        FROM @L l INNER JOIN inventory.Items i ON i.Id = l.ItemId;
        SET @PurchaseOrderId = NULL;
        SET @SourceText = N'Draft without an order (' + (SELECT PartyCode FROM masterdata.Parties WHERE Id = @SupplierId) + N')';
    END

    /* ---------- 4. Local lines (order, invoice, manual): quantity, warehouse, "Nothing more will come", caps */
    IF @SourceKind <> N'Container'
    BEGIN
        IF @WarehouseId IS NULL SELECT TOP (1) @WarehouseId = WarehouseId FROM @L WHERE WarehouseId IS NOT NULL ORDER BY LineNumber;
        IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1)
            THROW 63000, 'The warehouse the goods are received into is not found or inactive.', 1;
        -- (72) of any branch (as before), at the bottom of the tree (script 70): "Receive into" is the default of the
        --      lines, so it is held to their rule, as the default warehouse of the Excel import is.
        IF @WarehouseId IS NOT NULL AND masterdata.fn_Warehouse_IsLeaf(@WarehouseId) = 0
        BEGIN
            SET @Msg = N'The warehouse ' + (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId)
                     + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.';
            THROW 63000, @Msg, 1;
        END

        -- 0 PIECES ONLY WITH "NOTHING MORE WILL COME" on a line of an order (rules 14, 17): the usual way the rest of an
        -- order line is settled when the supplier says it will never arrive, after a partial delivery was received.
        -- The checks below still apply to such a line (an order line, a reason, an active warehouse); a line of a
        -- manual receipt or of an invoice without an order never takes 0.
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): ' +
            CASE WHEN i.IsActive = 0 THEN N'item ' + i.ItemCode + N' is inactive.'
                 WHEN l.Quantity = 0 AND l.CloseShort = 0 AND l.PoLineId IS NULL THEN N'the received quantity must be more than 0.'
                 WHEN l.Quantity = 0 AND l.CloseShort = 0
                     THEN N'the received quantity must be more than 0, or tick "Nothing more will come" to settle the rest of the order line.'
                 WHEN l.WarehouseId IS NULL THEN N'choose the warehouse the goods are received into.'
                 WHEN w.Id IS NULL OR w.IsActive = 0 THEN N'warehouse not found or inactive.'
                 -- (72) a line's warehouse is at the bottom of the tree (script 70)
                 WHEN masterdata.fn_Warehouse_IsLeaf(w.Id) = 0 THEN N'warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
                 WHEN l.PoLineId IS NULL THEN N'"Nothing more will come" applies to a line of a purchase order.'
                 ELSE N'give the reason why nothing more will come.' END
        FROM @L l
        INNER JOIN inventory.Items i          ON i.Id = l.ItemId
        LEFT  JOIN masterdata.Warehouses w    ON w.Id = l.WarehouseId
        WHERE i.IsActive = 0 OR (l.Quantity = 0 AND l.CloseShort = 0) OR l.WarehouseId IS NULL OR w.Id IS NULL OR w.IsActive = 0
           OR masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
           OR (l.CloseShort = 1 AND l.PoLineId IS NULL)
           OR (l.CloseShort = 1 AND l.VarianceReasonCode IS NULL AND l.VarianceReason IS NULL)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63000, @Msg, 1;

        -- the caps of Post (63011), so a draft never promises what cannot be posted
        SELECT TOP (1) @Msg = N'Line ' + CAST(q.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(q.Qty AS NVARCHAR(20))
                              + N' pcs received but only ' + CAST(p.MaxOutsideBase AS NVARCHAR(20))
                              + N' remain to receive on the order line outside containers.'
        FROM (SELECT PoLineId, OrderId = MIN(PurchaseOrderId), ItemId = MIN(ItemId), Qty = SUM(QuantityBase), LineNumber = MIN(LineNumber)
              FROM @L WHERE PoLineId IS NOT NULL GROUP BY PoLineId) q
        CROSS APPLY purchase.fn_PoLine_Progress(q.OrderId) p
        INNER JOIN inventory.Items i ON i.Id = q.ItemId
        WHERE p.PoLineId = q.PoLineId AND q.Qty > p.MaxOutsideBase
        ORDER BY q.LineNumber;
        IF @Msg IS NOT NULL THROW 63011, @Msg, 1;

        SELECT TOP (1) @Msg = N'Line ' + CAST(q.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(q.Qty AS NVARCHAR(20))
                              + N' pcs received but only '
                              + CAST(CASE WHEN pil.QuantityBase - pil.ReceivedQuantityBase > 0 THEN pil.QuantityBase - pil.ReceivedQuantityBase ELSE 0 END AS NVARCHAR(20))
                              + N' remain to receive on invoice ' + ISNULL(@InvNo, N'#' + CAST(@PurchaseInvoiceId AS NVARCHAR(10))) + N'.'
        FROM (SELECT InvoiceLineId, ItemId = MIN(ItemId), Qty = SUM(QuantityBase), LineNumber = MIN(LineNumber)
              FROM @L WHERE InvoiceLineId IS NOT NULL AND PoLineId IS NULL GROUP BY InvoiceLineId) q
        INNER JOIN purchase.PurchaseDocumentLines pil ON pil.Id = q.InvoiceLineId
        INNER JOIN inventory.Items i                  ON i.Id = q.ItemId
        WHERE q.Qty > pil.QuantityBase - pil.ReceivedQuantityBase
        ORDER BY q.LineNumber;
        IF @Msg IS NOT NULL THROW 63011, @Msg, 1;

        IF @BranchId IS NULL SET @BranchId = (SELECT BranchId FROM masterdata.Warehouses WHERE Id = @WarehouseId);
    END

    IF @BranchId IS NULL THROW 63000, 'Choose the branch of the goods receipt.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 63000, 'Branch not found or inactive.', 1;

    /* ---------- 5. Write */
    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            IF @SourceKind = N'Container'
            BEGIN
                -- ONE OPEN RECEIPT PER CONTAINER: the container row is locked, then the receipt is inserted only when none
                -- is open (the unique index UX_GoodsReceipts_OpenContainer would refuse a second with a raw 2601)
                DECLARE @OpenId INT, @OpenNo NVARCHAR(30);
                SELECT @CtStatus = Status FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @ContainerId;
                SELECT TOP (1) @OpenId = Id, @OpenNo = DocumentNumber
                FROM purchase.GoodsReceipts WITH (UPDLOCK, HOLDLOCK)
                WHERE ContainerId = @ContainerId AND Status < 3
                ORDER BY Status DESC, Id DESC;
                IF @OpenId IS NOT NULL
                BEGIN
                    SET @Msg = N'Container ' + @Ref + N' already has ' + ISNULL(N'goods receipt ' + @OpenNo, N'a draft goods receipt') + N'. Open it instead.';
                    THROW 63013, @Msg, 1;
                END
                IF @CtStatus NOT BETWEEN 2 AND 5
                    THROW 63010, 'Only a confirmed container that is not received yet can be received.', 1;
            END

            INSERT INTO purchase.GoodsReceipts (DocumentTypeId, DocumentDate, BranchId, WarehouseId, SupplierId, SourceKind, ContainerId,
                                                PurchaseOrderId, PurchaseInvoiceId, MovementId, IsAuto, SupplierReference, Notes, Status, CreatedBy)
            SELECT @TypeId, @DocumentDate, @BranchId, @WarehouseId, @SupplierId, @SourceKind, @ContainerId,
                   @PurchaseOrderId, @PurchaseInvoiceId, @MovementId, @IsAuto, @SupplierReference, @Notes, 1, @UserId
            WHERE @SourceKind <> N'Container'
               OR NOT EXISTS (SELECT 1 FROM purchase.GoodsReceipts x WHERE x.ContainerId = @ContainerId AND x.Status < 3);
            IF @@ROWCOUNT = 0
            BEGIN
                SET @Msg = N'Container ' + @Ref + N' already has a goods receipt. Open it instead.';
                THROW 63013, @Msg, 1;
            END
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId)
            VALUES (@Id, N'Created', LEFT(@SourceText + N' (number assigned on posting)', 500), @UserId);
            IF @SourceKind = N'Container'
                INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
                VALUES (@ContainerId, N'Event', LEFT(N'Draft goods receipt created' + ISNULL(N' when ' + @MovNo + N' was completed', N'')
                                                     + N': the goods enter the stock when it is posted.', 500), @UserId);
        END
        ELSE
        BEGIN
            UPDATE purchase.GoodsReceipts
            SET DocumentDate = @DocumentDate, BranchId = @BranchId, WarehouseId = @WarehouseId, SupplierId = @SupplierId,
                PurchaseOrderId = @PurchaseOrderId, SupplierReference = @SupplierReference, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id AND Status = 1 AND (@RowVersion IS NULL OR RowVersion = @RowVersion);
            IF @@ROWCOUNT = 0 THROW 63004, 'This goods receipt was modified by another user. Reload the page and try again.', 1;

            -- a draft has no matches; removed in case, so the lines can go
            DELETE m FROM purchase.GoodsReceiptInvoiceMatches m
            INNER JOIN purchase.GoodsReceiptLines l ON l.Id = m.GoodsReceiptLineId
            WHERE l.GoodsReceiptId = @Id;
            DELETE FROM purchase.GoodsReceiptLines WHERE GoodsReceiptId = @Id;

            INSERT INTO purchase.GoodsReceiptAudit (GoodsReceiptId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @L) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        -- EXPECTED = what is still to receive now, this receipt left out (its old lines are deleted above)
        IF @SourceKind = N'Order'
            UPDATE l SET ExpectedQuantityBase = p.ToReceiveBase
            FROM @L l CROSS APPLY purchase.fn_PoLine_Progress(l.PurchaseOrderId) p
            WHERE p.PoLineId = l.PoLineId;
        IF @SourceKind = N'Invoice'
            UPDATE l SET ExpectedQuantityBase = t.ToReceiveBase
            FROM @L l INNER JOIN purchase.fn_InvoiceLine_ToReceive(@PurchaseInvoiceId) t ON t.InvoiceLineId = l.InvoiceLineId;

        -- A LINE OF 0 THAT SETTLES NOTHING is refused: nothing is left to receive on its order line (or invoice line) now
        -- - everything received, settled, travelling in containers or on other draft receipts - so it would post as a no-op.
        SET @Msg = NULL;
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): nothing is left to receive on the '
                              + CASE WHEN @SourceKind = N'Invoice' THEN N'invoice line' ELSE N'order line' END
                              + N', so "Nothing more will come" has nothing to settle.'
        FROM @L l INNER JOIN inventory.Items i ON i.Id = l.ItemId
        WHERE @SourceKind <> N'Container' AND l.Quantity = 0 AND l.CloseShort = 1 AND ISNULL(l.ExpectedQuantityBase, 0) = 0
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 63009, @Msg, 1;

        INSERT INTO purchase.GoodsReceiptLines (GoodsReceiptId, LineNumber, ItemId, ItemUnitId, Quantity, PackingFormula,
                                                ExpectedQuantityBase, VarianceReasonCode, VarianceReason, CloseShort, WarehouseId,
                                                SupplierId, PurchaseOrderId, PoLineId, InvoiceLineId, ContainerLineId, ExpiryDate,
                                                ManualUnitCostBase, Notes)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, l.Quantity, l.PackingFormula,
               l.ExpectedQuantityBase, l.VarianceReasonCode, l.VarianceReason, l.CloseShort, l.WarehouseId,
               l.SupplierId, l.PurchaseOrderId, l.PoLineId, l.InvoiceLineId, l.ContainerLineId, l.ExpiryDate,
               l.ManualUnitCostBase, l.Notes
        FROM @L l;

        UPDATE g
        SET TotalExpectedBase = x.Expected, TotalReceivedBase = x.Received
        FROM purchase.GoodsReceipts g
        CROSS APPLY (SELECT Expected = ISNULL(SUM(ISNULL(l.ExpectedQuantityBase, l.QuantityBase)), 0),
                            Received = ISNULL(SUM(l.QuantityBase), 0)
                     FROM purchase.GoodsReceiptLines l WHERE l.GoodsReceiptId = g.Id) x
        WHERE g.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

