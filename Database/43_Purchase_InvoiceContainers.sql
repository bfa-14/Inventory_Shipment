/* =====================================================================================
   Inventory_Shipment - 43: A PURCHASE INVOICE AND ITS CONTAINERS (prompt 41)

   An invoice made directly from a purchase order can be "shipped in containers": its goods enter the stock at the
   offload of the containers it is linked to, not when it is posted. The link is made, undone and completed from the
   invoice, a container line at a time, and an invoice may be partly in containers - the rest is linked later.

   Rules
     - The switch is the receipt mode of a purchase invoice: 1 = stock in on posting, 2 = stock in at the container
       offload ("shipped in containers"). Save takes it again (NULL = unchanged, 1 on creation). A line linked to a
       container forces 2; switching to 1 while a line is linked is refused (65026). Mode 2 needs an invoice of a
       purchase order whose lines all come from the order (65000). In mode 1, the containers of the order plus what is
       invoiced outside containers cannot exceed an order line (65026): the goods would be received twice.
     - CreateFromSource PO -> PINV is allowed for an order with containers (it was refused, 65021) and makes the invoice
       in mode 2. CreateFromContainers keeps making it in mode 2.
     - Post in mode 2: no stock movement (as before), the exporter's reference required (65018) and no own charges
       (65020), as for imported invoices. Lines not in a container yet are allowed: they are linked after posting and
       enter the stock with the containers (see the Check at the end).
     - Linking (usp_PurchaseInvoice_LinkContainers): an invoice of a purchase order, draft or posted in mode 2 (a draft
       still in mode 1 switches to 2); containers of that order still Draft or Confirmed (65027 otherwise); a quantity
       within what the container line has loaded and not yet invoiced and within the invoice's pieces of that order line
       outside containers (65019). The invoice line is SPLIT: one line per container line, the rest stays unlinked. A
       part that is not a whole number of the line's unit goes to the base unit (price per base unit, as CreateFromSource
       does). The document total is kept: a rounding difference goes on the last line split.
     - Unlinking (usp_PurchaseInvoice_UnlinkContainer): the container still Draft or Confirmed, nothing received. Its
       invoice lines go back into the unlinked line of the same order line, item, unit, price, discount, warehouse.
     - An invoice in mode 2 is not "invoiced directly" for the order: its pieces outside containers stay available for
       new containers (usp_PurchaseDocument_Get, usp_Container_AvailablePoLines / _Save / _PlanFromOrder / _CreateBatch).
     - Adding containers from an invoice uses the order's procedures with @ForInvoiceId (default NULL = as before):
       PlanFromOrder plans only what the invoice has outside containers, CreateBatch refuses more, and all three accept
       the order once that invoice has closed it (fully invoiced on posting). The API then links them in the same
       transaction.
     - logistics.ContainerInvoices is NOT written: it is the unused table of the model before script 27. The order
       lines count what is invoiced through the invoice lines (ContainerLineId), so nothing else changes on them.

   Objects
     purchase.fn_PurchaseInvoice_TakesContainers / _Unlinked / _ItemContainers (new functions)
     purchase.usp_PurchaseDocument_Save / _Post / _CreateFromSource / _Get (re-created from their current bodies:
       29, 42, 27, 27 - the approval of script 42 is kept in Post)
     logistics.usp_Container_AvailablePoLines / _Save (27), _PlanFromOrder / _CreateBatch (28) (re-created)
     purchase.usp_PurchaseInvoice_ContainerSummary / _LinkCandidates / _LinkContainers / _UnlinkContainer (new)
     purchase.usp_PurchaseDocument_Get: header + ContainersNeeded (ContainerCount already counts the linked containers)

   Errors: 65026 receipt mode refused (lines linked, or the goods would be received twice), 65027 the container has
           started moving (or is cancelled), 65028 the invoice cannot be linked (not from an order, received on posting,
           landed cost adjustment, returns, nothing left to split); 65019 container line mismatch / exceeded,
           65020 own charges, 65000 validation, 65004 concurrency, 65006 not found, 65010 invalid status.
   ("The one-item rule of prompt 37" named by the prompt was not found anywhere: this script handles several items.)

   Requires scripts 27, 28 and 42. Idempotent, additive: re-applied at every API start-up through Schema.sql.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF COL_LENGTH(N'purchase.PurchaseDocumentLines', N'ContainerLineId') IS NULL
   OR OBJECT_ID(N'logistics.usp_Container_PlanFromOrder', N'P') IS NULL
   OR OBJECT_ID(N'purchase.ApprovalSettings', N'U') IS NULL
   OR TYPE_ID(N'logistics.tvp_ContainerLineQty') IS NULL
BEGIN
    RAISERROR ('Run scripts 27, 28 and 42 before this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ================================================================== 1. Helpers */

-- 1 when @InvoiceId is a purchase invoice of @PurchaseOrderId that can still take containers: a draft, or a posted
-- invoice shipped in containers (receipt mode 2). Posting such an invoice may close its order (fully invoiced); the
-- container procedures accept that closed order when they are called for this invoice (@ForInvoiceId).
CREATE OR ALTER FUNCTION purchase.fn_PurchaseInvoice_TakesContainers (@PurchaseOrderId INT, @InvoiceId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN @InvoiceId IS NOT NULL
                 AND EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d
                             INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                             WHERE d.Id = @InvoiceId AND dt.Code = N'PINV' AND d.SourceDocumentId = @PurchaseOrderId
                               AND (d.Status = 1 OR (d.Status = 2 AND d.ReceiptMode = 2)))
                THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END;
END
GO

-- What an invoice has not placed in a container yet, per ORDER line: a container line comes from one order line, and
-- the invoice line it is linked to must come from the same one.
CREATE OR ALTER FUNCTION purchase.fn_PurchaseInvoice_Unlinked (@InvoiceId INT)
RETURNS TABLE
AS
RETURN
    SELECT PoLineId = l.SourceLineId, l.ItemId, UnlinkedBase = SUM(l.QuantityBase)
    FROM purchase.PurchaseDocumentLines l
    WHERE l.DocumentId = @InvoiceId AND l.ContainerLineId IS NULL AND l.SourceLineId IS NOT NULL
    GROUP BY l.SourceLineId, l.ItemId;
GO

-- An invoice per item: invoiced, linked to containers, not linked yet, and the pieces in a container of the item
-- (its Container unit, script 25; NULL when the item has none).
CREATE OR ALTER FUNCTION purchase.fn_PurchaseInvoice_ItemContainers (@InvoiceId INT)
RETURNS TABLE
AS
RETURN
    SELECT l.ItemId,
           InvoicedBase     = SUM(l.QuantityBase),
           LinkedBase       = SUM(CASE WHEN l.ContainerLineId IS NOT NULL THEN l.QuantityBase ELSE 0 END),
           UnlinkedBase     = SUM(CASE WHEN l.ContainerLineId IS NULL THEN l.QuantityBase ELSE 0 END),
           ContainersLinked = COUNT(DISTINCT cl.ContainerId),
           PcsPerContainer  = MAX(cnt.PackingFormula)
    FROM purchase.PurchaseDocumentLines l
    LEFT  JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
    OUTER APPLY (SELECT TOP (1) u.PackingFormula FROM inventory.ItemUnits u
                 INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
                 WHERE u.ItemId = l.ItemId AND t.IsContainer = 1 AND u.PackingFormula > 0
                 ORDER BY u.Id) cnt
    WHERE l.DocumentId = @InvoiceId
    GROUP BY l.ItemId;
GO

/* ================================================================== 2. Save: the switch, invoices partly in containers */

-- Re-created (43) from the body of script 29: receipt mode chosen on a purchase invoice, linked and unlinked lines side by side.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Save
    @Id                  INT            = NULL,
    @DocumentTypeCode    NVARCHAR(20),
    @DocumentDate        DATE,
    @ExpectedDate        DATE           = NULL,
    @BranchId            INT,
    @WarehouseId         INT = NULL,
    @SupplierId          INT,
    @CurrencyId          INT            = NULL,
    @RateType            TINYINT        = 1,
    @ExchangeRate        DECIMAL(18,6)  = NULL,
    @SupplierReference   NVARCHAR(100)  = NULL,
    @Notes               NVARCHAR(1000) = NULL,
    @Lines               purchase.tvp_PurchaseDocumentLine READONLY,
    @MaxDiscountPercent  DECIMAL(9,4)   = 100,
    @SourceDocumentId    INT            = NULL,
    @RowVersion          BINARY(8)      = NULL,
    @UserId              INT            = NULL,
    @ReceiptMode         TINYINT        = NULL,    -- NULL = unchanged (1 on creation)
    @ExporterReference   NVARCHAR(50)   = NULL,
    @CommercialInvoiceNo NVARCHAR(50)   = NULL,
    @LineContainers      purchase.tvp_LineContainer READONLY,   -- invoice from containers: the container line of every line
    @NewId               INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* The warehouse lives on the LINES. The header keeps one so that document lists, filters,
       reports and exports still have a warehouse to show; when the caller does not send one it is
       taken from the first line. */
    IF @WarehouseId IS NULL
        SELECT TOP (1) @WarehouseId = WarehouseId FROM @Lines ORDER BY LineNumber;

    SET @SupplierReference = NULLIF(LTRIM(RTRIM(@SupplierReference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @ExporterReference = NULLIF(LTRIM(RTRIM(@ExporterReference)), N'');
    SET @CommercialInvoiceNo = NULLIF(LTRIM(RTRIM(@CommercialInvoiceNo)), N'');
    IF @ReceiptMode IS NOT NULL AND @ReceiptMode NOT IN (1, 2) THROW 65000, 'Receipt mode must be 1 (on posting) or 2 (on container offload).', 1;
    IF @ReceiptMode = 2 AND @DocumentTypeCode <> N'PINV' THROW 65000, 'Only purchase invoices can be received on container offload.', 1;

    DECLARE @TypeId INT, @Direction SMALLINT, @Cur INT, @Rate DECIMAL(18,6);
    EXEC purchase.usp_PurchaseDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId, @SupplierId,
         @CurrencyId, @RateType, @ExchangeRate, @MaxDiscountPercent, @SourceDocumentId, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @Cur OUTPUT, @Rate OUTPUT;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status <> 1 THROW 65005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 65000, 'The document type cannot be changed.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND ISNULL(SourceDocumentId, 0) <> ISNULL(@SourceDocumentId, 0))
            THROW 65000, 'The source document cannot be changed.', 1;
        -- (43) A container is unlinked from the Containers card of the invoice (usp_PurchaseInvoice_UnlinkContainer),
        --      never by saving the invoice without the lines that are on it.
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines pl
                   WHERE pl.DocumentId = @Id AND pl.ContainerLineId IS NOT NULL
                     AND NOT EXISTS (SELECT 1 FROM @LineContainers x WHERE x.ContainerLineId = pl.ContainerLineId))
        BEGIN
            IF @ReceiptMode = 1 THROW 65026, 'Unlink the containers before switching off Shipped in containers.', 1;
            THROW 65019, 'This invoice is linked to containers: keep their lines, or unlink a container from the Containers card of the invoice.', 1;
        END
    END

    -- Lines linked to containers (all of them, or (43) only some: the rest is linked later) point to a container line of
    -- the same order line and item, within what is loaded and not yet invoiced elsewhere. A linked line forces receipt
    -- mode 2 ("shipped in containers").
    IF EXISTS (SELECT 1 FROM @LineContainers)
    BEGIN
        IF @DocumentTypeCode <> N'PINV' THROW 65019, 'Only purchase invoices can be linked to containers.', 1;
        IF @SourceDocumentId IS NULL THROW 65019, 'An invoice from containers must refer to its purchase order.', 1;
        IF EXISTS (SELECT 1 FROM @LineContainers x WHERE NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.LineNumber = x.LineNumber))
            THROW 65019, 'A container line is given for a line that does not exist.', 1;
        IF @Id IS NOT NULL AND EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id)
            THROW 65020, 'This invoice has its own charges. Remove them: the charges of an import are entered on its containers.', 1;

        DECLARE @CtMsg NVARCHAR(400);
        SELECT TOP (1) @CtMsg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
            CASE WHEN cl.Id IS NULL THEN N'the container line no longer exists.'
                 WHEN c.Status IN (6, 7, 8) THEN N'container ' + c.ContainerRef + N' is already offloaded, closed or cancelled.'
                 WHEN cl.PurchaseOrderId <> @SourceDocumentId THEN N'the container line belongs to another purchase order.'
                 WHEN cl.ItemId <> l.ItemId THEN N'the item differs from the container line.'
                 ELSE N'the order line differs from the container line.' END
        FROM @Lines l
        INNER JOIN @LineContainers x          ON x.LineNumber = l.LineNumber
        LEFT  JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
        LEFT  JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        WHERE cl.Id IS NULL OR c.Status IN (6, 7, 8) OR cl.PurchaseOrderId <> @SourceDocumentId
           OR cl.ItemId <> l.ItemId OR ISNULL(l.SourceLineId, 0) <> cl.PoLineId
        ORDER BY l.LineNumber;
        IF @CtMsg IS NOT NULL THROW 65019, @CtMsg, 1;

        SELECT TOP (1) @CtMsg = N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                + CAST(q.Here AS NVARCHAR(20)) + N' invoiced here + ' + CAST(ISNULL(o.Other, 0) AS NVARCHAR(20))
                                + N' in other invoices, but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' are loaded.'
        FROM (SELECT x.ContainerLineId, Here = SUM(l.Quantity * iu.PackingFormula)
              FROM @Lines l
              INNER JOIN @LineContainers x      ON x.LineNumber = l.LineNumber
              INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
              GROUP BY x.ContainerLineId) q
        INNER JOIN logistics.ContainerLines cl ON cl.Id = q.ContainerLineId
        INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        INNER JOIN inventory.Items i           ON i.Id = cl.ItemId
        OUTER APPLY (SELECT Other = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3 AND (@Id IS NULL OR pd.Id <> @Id)) o
        WHERE q.Here + ISNULL(o.Other, 0) > cl.QuantityBase
        ORDER BY c.ContainerRef, cl.LineNumber;
        IF @CtMsg IS NOT NULL THROW 65019, @CtMsg, 1;

        IF @ReceiptMode = 1 THROW 65026, 'Unlink the containers before switching off Shipped in containers.', 1;
        SET @ReceiptMode = 2;
    END

    -- (43) "Shipped in containers" (receipt mode 2) is chosen on a purchase invoice: NULL = unchanged (1 on creation).
    DECLARE @EffectiveMode TINYINT = CASE WHEN @DocumentTypeCode <> N'PINV' THEN 1
                                          ELSE COALESCE(@ReceiptMode, (SELECT ReceiptMode FROM purchase.PurchaseDocuments WHERE Id = @Id), 1) END;
    DECLARE @ModeMsg NVARCHAR(400);
    IF @EffectiveMode = 2
    BEGIN
        -- the goods enter the stock at the offload of the containers they are linked to: lines of the order only
        IF @SourceDocumentId IS NULL THROW 65000, 'Only an invoice created from a purchase order can be shipped in containers.', 1;
        SELECT TOP (1) @ModeMsg = N'Line ' + CAST(LineNumber AS NVARCHAR(10)) + N': only lines of the purchase order can be shipped in containers.'
        FROM @Lines WHERE SourceLineId IS NULL ORDER BY LineNumber;
        IF @ModeMsg IS NOT NULL THROW 65000, @ModeMsg, 1;
    END
    ELSE IF @DocumentTypeCode = N'PINV' AND @SourceDocumentId IS NOT NULL
    BEGIN
        -- received on posting: what the containers of the order hold plus what is invoiced outside containers cannot
        -- exceed the order line, or the same goods would be received twice
        SELECT TOP (1) @ModeMsg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): the containers of the order hold '
                                  + CAST(ct.Qty AS NVARCHAR(20)) + N' of the ' + CAST(pol.QuantityBase AS NVARCHAR(20))
                                  + N' ordered. Keep Shipped in containers on and link the invoice to them.'
        FROM (SELECT x.SourceLineId, Qty = SUM(x.Quantity * iu.PackingFormula), LineNumber = MIN(x.LineNumber)
              FROM @Lines x INNER JOIN inventory.ItemUnits iu ON iu.Id = x.ItemUnitId
              WHERE x.SourceLineId IS NOT NULL GROUP BY x.SourceLineId) l
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.SourceLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        CROSS APPLY (SELECT Qty = ISNULL(SUM(cl.QuantityBase), 0) FROM logistics.ContainerLines cl
                     INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                     WHERE cl.PoLineId = pol.Id AND c.Status <> 8) ct
        OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                     INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                     WHERE x.SourceLineId = pol.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2
                       AND (@Id IS NULL OR xd.Id <> @Id)) dir
        WHERE ct.Qty > 0 AND l.Qty + ISNULL(dir.Qty, 0) + ct.Qty > pol.QuantityBase
        ORDER BY l.LineNumber;
        IF @ModeMsg IS NOT NULL THROW 65026, @ModeMsg, 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO purchase.PurchaseDocuments (DocumentTypeId, DocumentNumber, DocumentDate, ExpectedDate, BranchId, WarehouseId, SupplierId,
                                                    CurrencyId, RateType, ExchangeRate, SupplierReference, Notes, Status, SourceDocumentId,
                                                    ReceiptMode, ExporterReference, CommercialInvoiceNo, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId, @SupplierId,
                    @Cur, @RateType, @Rate, @SupplierReference, @Notes, 1, @SourceDocumentId,
                    ISNULL(@ReceiptMode, 1), @ExporterReference, @CommercialInvoiceNo, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)')
                        + ISNULL(N' from ' + (SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @SourceDocumentId), N''), @UserId);
        END
        ELSE
        BEGIN
            UPDATE purchase.PurchaseDocuments
            SET DocumentDate = @DocumentDate, ExpectedDate = @ExpectedDate, BranchId = @BranchId, WarehouseId = @WarehouseId,
                SupplierId = @SupplierId, CurrencyId = @Cur, RateType = @RateType, ExchangeRate = @Rate,
                SupplierReference = @SupplierReference, Notes = @Notes,
                ReceiptMode = ISNULL(@ReceiptMode, ReceiptMode),
                ExporterReference = @ExporterReference, CommercialInvoiceNo = @CommercialInvoiceNo,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            -- Lines are replaced: manual charge allocations pointing at the old lines are dropped (the charges stay).
            DELETE a FROM purchase.PurchaseChargeAllocations a
            INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId
            WHERE c.DocumentKind = N'PINV' AND c.DocumentId = @Id;
            DELETE FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;

            INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        INSERT INTO purchase.PurchaseDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                                    UnitPrice, DiscountPercent, UnitCostBase, FobCostBase, ImportRowNumber, Notes, SourceLineId)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, l.WarehouseId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
               ISNULL(l.UnitPrice, ROUND(ISNULL(i.LastCost, 0) * iu.PackingFormula * @Rate, 4)),
               ISNULL(l.DiscountPercent, 0),
               CASE WHEN @DocumentTypeCode = N'PRET' THEN COALESCE(scl.LandedCostBase, src.UnitCostBase) END,   -- returns carry the LANDED cost (the container's for imports)
               CASE WHEN @DocumentTypeCode = N'PRET' THEN COALESCE(scl.FobCostBase, src.FobCostBase) END,
               l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N''), l.SourceLineId
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        LEFT  JOIN purchase.PurchaseDocumentLines src ON src.Id = l.SourceLineId
        LEFT  JOIN logistics.ContainerLines scl       ON scl.Id = src.ContainerLineId;

        UPDATE pl SET ContainerLineId = x.ContainerLineId
        FROM purchase.PurchaseDocumentLines pl
        INNER JOIN @LineContainers x ON x.LineNumber = pl.LineNumber
        WHERE pl.DocumentId = @Id;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / @Rate, 2), TotalLandedCostBase = ROUND(x.Amt / @Rate, 2) + d.TotalChargesBase
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        -- the value basis of the container charges follows the invoice prices
        IF EXISTS (SELECT 1 FROM @LineContainers)
        BEGIN
            DECLARE @Cid INT;
            DECLARE cts CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT cl.ContainerId FROM @LineContainers x INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId;
            OPEN cts;
            FETCH NEXT FROM cts INTO @Cid;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
                FETCH NEXT FROM cts INTO @Cid;
            END
            CLOSE cts;
            DEALLOCATE cts;
        END

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 3. Post: shipped in containers */

-- Re-created (43) from the body of script 42 (approval kept): receipt mode 2 = exporter reference, no own charges, no stock movement.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Post
    @Id         INT,
    @RowVersion   BINARY(8) = NULL,
    @UserId       INT       = NULL,
    @FromApproval BIT       = 0      -- 1 = called by the approval
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE,
                @BranchId INT, @SupplierId INT, @Rate DECIMAL(18,6), @SourceId INT, @ReceiptMode TINYINT;

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @SupplierId = d.SupplierId, @Rate = d.ExchangeRate,
               @SourceId = d.SourceDocumentId, @ReceiptMode = d.ReceiptMode
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode = N'PO' AND ISNULL(@FromApproval, 0) = 1 AND @Status <> 5
            THROW 65010, 'Only a purchase order waiting for approval can be approved.', 1;
        IF (@TypeCode <> N'PO' OR ISNULL(@FromApproval, 0) = 0) AND @Status <> 1
            THROW 65010, 'Only draft documents can be posted.', 1;

        DECLARE @PostedWithoutApproval BIT = CASE WHEN @TypeCode = N'PO' AND ISNULL(@FromApproval, 0) = 0 THEN 1 ELSE 0 END;
        IF @PostedWithoutApproval = 1 AND purchase.fn_PurchaseOrder_NeedsApproval(@Id) = 1
            THROW 65013, 'This order needs approval: send it for approval.', 1;

        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id)
            THROW 65009, 'The document has no lines. Add at least one item before posting.', 1;
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsActive = 1)
            THROW 65008, 'The supplier is inactive.', 1;

        -- Imports: the goods are received by the container, not by this posting.
        DECLARE @ReceiveNow BIT = CASE WHEN @TypeCode = N'PINV' AND @ReceiptMode = 2 THEN 0 ELSE 1 END;

        DECLARE @FromContainers BIT = CASE WHEN @TypeCode = N'PINV' AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines
                                                                                WHERE DocumentId = @Id AND ContainerLineId IS NOT NULL) THEN 1 ELSE 0 END;
        -- (43) Shipped in containers: an imported invoice, linked to its containers now or later. Lines not in a container
        --      yet are allowed: they enter the stock at the offload of the containers they are linked to afterwards.
        IF @TypeCode = N'PINV' AND @ReceiptMode = 2
        BEGIN
            IF NULLIF(LTRIM(RTRIM((SELECT ExporterReference FROM purchase.PurchaseDocuments WHERE Id = @Id))), N'') IS NULL
                THROW 65018, 'The exporter reference is required on an imported invoice. Enter it before posting.', 1;
            IF EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id)
                THROW 65020, 'This invoice has its own charges. Remove them: the charges of an import are entered on its containers.', 1;
        END

        IF @FromContainers = 1
        BEGIN

            DECLARE @CtMsg NVARCHAR(400);
            SELECT TOP (1) @CtMsg = N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                                    + CASE WHEN c.Status IN (6, 7, 8) THEN N'the container is already offloaded, closed or cancelled.'
                                           ELSE CAST(q.Here AS NVARCHAR(20)) + N' invoiced here + ' + CAST(ISNULL(o.Posted, 0) AS NVARCHAR(20))
                                                + N' in posted invoices, but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' are loaded.' END
            FROM (SELECT ContainerLineId, Here = SUM(QuantityBase) FROM purchase.PurchaseDocumentLines
                  WHERE DocumentId = @Id GROUP BY ContainerLineId) q
            INNER JOIN logistics.ContainerLines cl ON cl.Id = q.ContainerLineId
            INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
            INNER JOIN inventory.Items i           ON i.Id = cl.ItemId
            OUTER APPLY (SELECT Posted = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                         INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                         WHERE pil.ContainerLineId = cl.Id AND pd.Status IN (2, 4) AND pd.Id <> @Id) o
            WHERE c.Status IN (6, 7, 8) OR q.Here + ISNULL(o.Posted, 0) > cl.QuantityBase
            ORDER BY c.ContainerRef, cl.LineNumber;
            IF @CtMsg IS NOT NULL THROW 65019, @CtMsg, 1;
        END

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 65000, @Msg, 1;

        IF @SourceId IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 2)
                THROW 65011, 'The source document is no longer open (cancelled or closed).', 1;

            IF @TypeCode = N'PINV'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units invoiced but only ' + CAST(s.QuantityBase - s.ReceivedQuantityBase AS NVARCHAR(20)) + N' remain on the order line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReceivedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
            IF @TypeCode = N'PRET'
            BEGIN
                SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                     + N' base units returned but only ' + CAST(s.QuantityBase - s.ReturnedQuantityBase AS NVARCHAR(20)) + N' can still be returned from the invoice line.'
                FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
                INNER JOIN purchase.PurchaseDocumentLines s ON s.Id = x.SourceLineId
                INNER JOIN inventory.Items i ON i.Id = s.ItemId
                WHERE x.Qty > s.QuantityBase - s.ReturnedQuantityBase
                ORDER BY x.LineNumber;
                IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
            END
        END

        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        IF @TypeCode = N'PINV'
        BEGIN
            -- FOB per base unit, then charges allocated over the lines, then landed cost per base unit.
            EXEC purchase.usp_PurchaseCharges_Allocate N'PINV', @Id, @Id;

            UPDATE l
            SET FobCostBase = (l.LineTotal / @Rate) / l.QuantityBase,
                AllocatedChargesBase = ISNULL(a.Total, 0),
                UnitCostBase = ((l.LineTotal / @Rate) + ISNULL(a.Total, 0)) / l.QuantityBase
            FROM purchase.PurchaseDocumentLines l
            OUTER APPLY (SELECT SUM(x.AmountBase) AS Total
                         FROM purchase.PurchaseChargeAllocations x
                         INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                         WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'PINV' AND c.DocumentId = @Id AND c.IncludeInLandedCost = 1) a
            WHERE l.DocumentId = @Id;

            UPDATE d
            SET TotalChargesBase = ISNULL(x.Charges, 0), TotalLandedCostBase = d.TotalAmountBase + ISNULL(x.Charges, 0)
            FROM purchase.PurchaseDocuments d
            CROSS APPLY (SELECT SUM(AllocatedChargesBase) AS Charges FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
            WHERE d.Id = @Id;
        END
        ELSE IF @TypeCode = N'PRET'
            UPDATE l SET UnitCostBase = ISNULL(l.UnitCostBase, ISNULL(inventory.fn_AverageCost(l.ItemId), 0))
            FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;

        IF @Direction = 1 AND @ReceiveNow = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, ISNULL(l.UnitCostBase, 0), l.FobCostBase FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId, 1;
        END

        IF @Direction <> 0 AND @ReceiveNow = 1
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Purchase', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM purchase.PurchaseDocumentLines l
            WHERE l.DocumentId = @Id;

            IF @Direction = 1
                UPDATE purchase.PurchaseDocumentLines SET ReceivedQuantityBase = QuantityBase WHERE DocumentId = @Id;
        END

        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @SourceId AND ReceivedQuantityBase < QuantityBase)
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 4, ClosedAtUtc = SYSUTCDATETIME(), ClosedBy = @UserId, CloseReason = N'Fully received' WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Closed', N'Fully received by ' + @Number, @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase + x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        UPDATE purchase.PurchaseDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id);
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 AND @ReceiveNow = 1 THEN N' written to the stock ledger'
                                       WHEN @ReceiveNow = 0 THEN N'; stock will be received when the container is offloaded'
                                       WHEN @PostedWithoutApproval = 1 THEN N' (approval not needed)'
                                       ELSE N' (order approved)' END
                                + CASE WHEN @TypeCode = N'PINV' THEN N'; landed charges ' + CAST((SELECT TotalChargesBase FROM purchase.PurchaseDocuments WHERE Id = @Id) AS NVARCHAR(30)) ELSE N'' END, @UserId);

        -- A purchase order posted without approval: the user who posts it is recorded as approver, as an approval does.
        IF @PostedWithoutApproval = 1
        BEGIN
            UPDATE purchase.PurchaseDocuments SET ApprovedAtUtc = SYSUTCDATETIME(), ApprovedBy = @UserId WHERE Id = @Id;

            DECLARE @RequireApproval BIT, @ApprovalLimit DECIMAL(19, 4);
            SELECT @RequireApproval = RequireApproval, @ApprovalLimit = ApprovalLimitBase FROM purchase.ApprovalSettings WHERE Id = 1;
            INSERT INTO purchase.PurchaseOrderApprovalEvents (PurchaseDocumentId, EventType, UserId, Note)
            VALUES (@Id, 7, @UserId,
                    CASE WHEN @RequireApproval = 0 THEN N'Approval not required'
                         ELSE N'Under the approval limit of ' + FORMAT(@ApprovalLimit, N'N2', N'en-US')
                              + ISNULL(N' ' + (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies
                                               WHERE IsBaseCurrency = 1 AND IsActive = 1), N'') END);
        END

        -- containers of an import: the invoice is known now (value basis of the charges, history)
        IF @FromContainers = 1
        BEGIN
            DECLARE @Cid INT;
            DECLARE cts CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT cl.ContainerId FROM purchase.PurchaseDocumentLines l
                INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                WHERE l.DocumentId = @Id;
            OPEN cts;
            FETCH NEXT FROM cts INTO @Cid;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
                INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
                VALUES (@Cid, N'Updated', N'Purchase invoice ' + @Number + N' posted', @UserId);
                FETCH NEXT FROM cts INTO @Cid;
            END
            CLOSE cts;
            DEALLOCATE cts;
        END

        COMMIT TRANSACTION;
        IF ISNULL(@FromApproval, 0) = 0 SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 4. CreateFromSource: an order with containers */

-- Re-created (43) from the body of script 27: an order with containers gives an invoice shipped in containers.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_CreateFromSource
    @SourceId       INT,
    @TargetTypeCode NVARCHAR(20),        -- PINV (from PO) | PRET (from PINV)
    @DocumentDate   DATE = NULL,         -- default today
    @Selection      purchase.tvp_SourceLineSelection READONLY,   -- lines + base quantities to take; empty = everything still available
    @UserId         INT  = NULL,
    @NewId          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @SrcType NVARCHAR(20), @Status TINYINT, @BranchId INT, @WarehouseId INT, @SupplierId INT, @CurrencyId INT, @RateType TINYINT, @SupplierRef NVARCHAR(100);
    SELECT @SrcType = dt.Code, @Status = d.Status, @BranchId = d.BranchId, @WarehouseId = d.WarehouseId, @SupplierId = d.SupplierId,
           @CurrencyId = d.CurrencyId, @RateType = d.RateType, @SupplierRef = d.SupplierReference
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceId;

    IF @SrcType IS NULL THROW 65006, 'Source document not found.', 1;
    IF @Status <> 2 THROW 65011, 'The source document must be approved / posted and still open.', 1;
    IF NOT ((@TargetTypeCode = N'PINV' AND @SrcType = N'PO') OR (@TargetTypeCode = N'PRET' AND @SrcType = N'PINV'))
        THROW 65011, 'Purchase orders become purchase invoices; purchase invoices become purchase returns.', 1;
    -- (43) An order with containers gives an invoice "shipped in containers" (receipt mode 2): its lines are linked to the
    --      containers afterwards (usp_PurchaseInvoice_LinkContainers). It used to be refused (65021).
    DECLARE @ReceiptMode TINYINT =
        CASE WHEN @SrcType = N'PO' AND EXISTS (SELECT 1 FROM logistics.ContainerLines cl INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                                               WHERE cl.PurchaseOrderId = @SourceId AND c.Status <> 8)
             THEN 2 END;

    -- Several drafts may be created from the same document: what is already in another DRAFT of the target type is not
    -- offered again. A selection takes only the given lines / base quantities.
    DECLARE @HasSelection BIT = CASE WHEN EXISTS (SELECT 1 FROM @Selection) THEN 1 ELSE 0 END;
    IF @HasSelection = 1
    BEGIN
        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg = CASE WHEN l.Id IS NULL THEN N'A selected line does not belong to the source document.'
                                   WHEN sel.QuantityBase <= 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the quantity must be greater than zero.'
                                   ELSE N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + CAST(sel.QuantityBase AS NVARCHAR(20))
                                        + N' base units selected but only ' + CAST(av.Available AS NVARCHAR(20))
                                        + N' are still available (the rest is in posted or draft documents).' END
        FROM @Selection sel
        LEFT JOIN purchase.PurchaseDocumentLines l ON l.Id = sel.SourceLineId AND l.DocumentId = @SourceId
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 INNER JOIN inventory.DocumentTypes xt ON xt.Id = xd.DocumentTypeId
                 WHERE x.SourceLineId = l.Id AND xd.Status = 1 AND xt.Code = @TargetTypeCode) dr
    CROSS APPLY (SELECT Available = CASE WHEN @SrcType = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                         ELSE l.QuantityBase - l.ReturnedQuantityBase END - ISNULL(dr.Qty, 0)) av
        WHERE l.Id IS NULL OR sel.QuantityBase <= 0 OR sel.QuantityBase > av.Available
        ORDER BY sel.SourceLineId;
        IF @Msg IS NOT NULL THROW 65011, @Msg, 1;
    END

    -- Remaining quantity per line; when it is not a whole number of the line's unit, the new line uses the BASE unit
    -- (price converted per base unit) so nothing is over-received or over-returned.
    DECLARE @Lines purchase.tvp_PurchaseDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
    SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber), l.ItemId, c.ItemUnitId, l.WarehouseId, l.ExpiryDate,
           c.Quantity, c.UnitPrice, l.DiscountPercent, NULL, l.Notes, l.Id
    FROM purchase.PurchaseDocumentLines l
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 INNER JOIN inventory.DocumentTypes xt ON xt.Id = xd.DocumentTypeId
                 WHERE x.SourceLineId = l.Id AND xd.Status = 1 AND xt.Code = @TargetTypeCode) dr
    CROSS APPLY (SELECT Available = CASE WHEN @SrcType = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                         ELSE l.QuantityBase - l.ReturnedQuantityBase END - ISNULL(dr.Qty, 0)) av
    LEFT JOIN @Selection sel ON sel.SourceLineId = l.Id
    CROSS APPLY (SELECT Remaining = CASE WHEN @HasSelection = 1 THEN ISNULL(sel.QuantityBase, 0) ELSE av.Available END) r
    CROSS APPLY (SELECT ItemUnitId = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.ItemUnitId
                                          ELSE (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = l.ItemId AND IsBaseUnit = 1) END,
                        Quantity   = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN r.Remaining / l.PackingFormula ELSE r.Remaining END,
                        UnitPrice  = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.UnitPrice ELSE ROUND(l.UnitPrice / l.PackingFormula, 4) END) c
    WHERE l.DocumentId = @SourceId AND r.Remaining > 0;

    IF NOT EXISTS (SELECT 1 FROM @Lines) THROW 65011, 'Nothing is left on the source document: everything is already in posted or draft documents.', 1;

    EXEC purchase.usp_PurchaseDocument_Save
         @Id = NULL, @DocumentTypeCode = @TargetTypeCode, @DocumentDate = @DocumentDate, @ExpectedDate = NULL,
         @BranchId = @BranchId, @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @CurrencyId = @CurrencyId,
         @RateType = @RateType, @ExchangeRate = NULL, @SupplierReference = @SupplierRef, @Notes = NULL,
         @Lines = @Lines, @MaxDiscountPercent = 100, @SourceDocumentId = @SourceId, @RowVersion = NULL, @UserId = @UserId,
         @ReceiptMode = @ReceiptMode, @NewId = @NewId OUTPUT;
END
GO

/* ================================================================== 5. Get: containers needed */

-- Re-created (43) from the body of script 27: header ContainersNeeded; an invoice shipped in containers is not "invoiced directly".
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, sp.Phone AS SupplierPhone, sp.Email AS SupplierEmail, sp.Address AS SupplierAddress,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo, d.ReceiptMode, d.Notes, d.Status,
           IsContainerBound = CAST(CASE WHEN EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines x
                                                    WHERE x.DocumentId = d.Id AND x.ContainerLineId IS NOT NULL) THEN 1 ELSE 0 END AS BIT),
           ContainerCount = CASE WHEN dt.Code = N'PO'
                                 THEN (SELECT COUNT(DISTINCT cl.ContainerId) FROM logistics.ContainerLines cl
                                       INNER JOIN logistics.Containers c9 ON c9.Id = cl.ContainerId
                                       WHERE cl.PurchaseOrderId = d.Id AND c9.Status <> 8)
                                 ELSE (SELECT COUNT(DISTINCT cl.ContainerId) FROM purchase.PurchaseDocumentLines x
                                       INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId
                                       WHERE x.DocumentId = d.Id) END,
           LoadedBase = CASE WHEN dt.Code = N'PO'
                             THEN ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                                          INNER JOIN logistics.Containers c9 ON c9.Id = cl.ContainerId
                                          WHERE cl.PurchaseOrderId = d.Id AND c9.Status <> 8), 0) END,
           ContainerChargesBase = cch.Share,
           ContainersNeeded = need.Containers,     -- (43) invoices: sum over the items of the pieces / pieces per container
           d.ApprovalRequestedAtUtc, d.ApprovalRequestedBy, rqu.FullName AS ApprovalRequestedByName,
           d.ApprovedAtUtc, d.ApprovedBy, apu.FullName AS ApprovedByName, d.ApprovalChannel,
           d.RejectedAtUtc, d.RejectedBy, rju.FullName AS RejectedByName, d.RejectReason,
           OrderedBase = prog.Ordered, InvoicedBase = prog.Invoiced, InDraftInvoicesBase = ISNULL(drf.InDraft, 0),
           InvoicingStatus = CASE WHEN dt.Code <> N'PO' THEN NULL WHEN ISNULL(prog.Invoiced, 0) = 0 THEN 0
                                  WHEN prog.Invoiced >= prog.Ordered THEN 2 ELSE 1 END,      -- 0 not, 1 partially, 2 fully invoiced
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase, d.TotalChargesBase, d.TotalLandedCostBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber, sdt.Code AS SourceDocumentTypeCode,
           d.SourceShortageId, sh.DocumentNumber AS SourceShortageNumber,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.ClosedAtUtc, d.ClosedBy, ku.FullName AS ClosedByName, d.CloseReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN inventory.DocumentTypes sdt ON sdt.Id = src.DocumentTypeId
    LEFT  JOIN inventory.ShortageDocuments sh ON sh.Id = d.SourceShortageId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    LEFT  JOIN security.Users ku ON ku.Id = d.ClosedBy
    LEFT  JOIN security.Users rqu ON rqu.Id = d.ApprovalRequestedBy
    LEFT  JOIN security.Users apu ON apu.Id = d.ApprovedBy
    LEFT  JOIN security.Users rju ON rju.Id = d.RejectedBy
    OUTER APPLY (SELECT Ordered = SUM(pl.QuantityBase), Invoiced = SUM(pl.ReceivedQuantityBase)
                 FROM purchase.PurchaseDocumentLines pl WHERE pl.DocumentId = d.Id) prog
    OUTER APPLY (SELECT InDraft = SUM(x.QuantityBase)
                 FROM purchase.PurchaseDocumentLines pl
                 INNER JOIN purchase.PurchaseDocumentLines x ON x.SourceLineId = pl.Id
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId AND xd.Status = 1
                 WHERE pl.DocumentId = d.Id) drf
    OUTER APPLY (SELECT Share = SUM(a.AmountBase * CAST(x.QuantityBase AS DECIMAL(18,6)) / NULLIF(cl.QuantityBase, 0))
                 FROM purchase.PurchaseDocumentLines x
                 INNER JOIN logistics.ContainerLines cl            ON cl.Id = x.ContainerLineId
                 INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id
                 INNER JOIN logistics.ContainerCharges ch          ON ch.Id = a.ChargeId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1
                 WHERE x.DocumentId = d.Id) cch
    OUTER APPLY (SELECT Containers = CASE WHEN dt.Code = N'PINV'
                                          THEN CAST(SUM(CAST(s.InvoicedBase AS DECIMAL(19,4)) / s.PcsPerContainer) AS DECIMAL(18,2)) END
                 FROM purchase.fn_PurchaseInvoice_ItemContainers(d.Id) s) need
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal,
           l.UnitCostBase, LandedCostBase = l.UnitCostBase, l.FobCostBase, l.AllocatedChargesBase,
           l.ReceivedQuantityBase, l.ReturnedQuantityBase, l.ShippedQuantityBase,
           AllocatedToContainersBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(ct.Allocated, 0)
                                            WHEN l.ContainerLineId IS NOT NULL THEN l.QuantityBase ELSE 0 END,
           TransitBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(ct.Transit, 0)
                              WHEN lct.Status IN (3, 4, 5) THEN l.QuantityBase ELSE 0 END,
           RemainingBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReturnedQuantityBase END,
           AvailableForContainerBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - ISNULL(ct.Allocated, 0) - ISNULL(dir.Qty, 0) END,
           InvoicedDirectBase = CASE WHEN dt.Code = N'PO' THEN ISNULL(dir.Qty, 0) END,
           l.ContainerLineId, ContainerId = lcl.ContainerId, ContainerRef = lct.ContainerRef, ContainerNo = lct.ContainerNo,
           ContainerStatus = lct.Status,
           ContainerChargesBase = CASE WHEN l.ContainerLineId IS NOT NULL THEN ISNULL(lch.Share, 0) END,
           EstimatedLandedCostBase = CASE WHEN l.ContainerLineId IS NOT NULL
                                          THEN COALESCE(lcl.LandedCostBase,
                                                        ISNULL(l.FobCostBase, l.LineTotal / NULLIF(d.ExchangeRate, 0) / NULLIF(l.QuantityBase, 0))
                                                        + ISNULL(lch.Share, 0) / NULLIF(l.QuantityBase, 0)) END,
           InDraftDocumentsBase = ISNULL(dr.Qty, 0),
           AvailableToInvoiceBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase - ISNULL(dr.Qty, 0) END,
           l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           ItemLastCost = i.LastCost, ItemAverageCost = i.AverageCost, ItemFobCost = i.FobCost
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w      ON w.Id = l.WarehouseId
    OUTER APPLY (SELECT Allocated = SUM(cl.QuantityBase),
                        Transit   = SUM(CASE WHEN c.Status IN (3, 4, 5) THEN cl.QuantityBase - ISNULL(cl.ReceivedQuantityBase, 0) ELSE 0 END)
                 FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8) ct
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2 AND dt.Code = N'PO') dir
    LEFT  JOIN logistics.ContainerLines lcl ON lcl.Id = l.ContainerLineId
    LEFT  JOIN logistics.Containers lct     ON lct.Id = lcl.ContainerId
    OUTER APPLY (SELECT Charges = SUM(a.AmountBase)
                 FROM logistics.ContainerChargeAllocations a
                 INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1
                 WHERE a.ContainerLineId = l.ContainerLineId) lcc
    OUTER APPLY (SELECT Share = lcc.Charges * CAST(l.QuantityBase AS DECIMAL(18,6)) / NULLIF(lcl.QuantityBase, 0)) lch
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND xd.Status = 1) dr
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM purchase.PurchaseDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.PurchaseDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    SELECT Relation = N'Source', x.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments d
    INNER JOIN purchase.PurchaseDocuments x ON x.Id = d.SourceDocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE d.Id = @Id
    UNION ALL
    SELECT N'Child', x.Id, dt.Code, dt.Name, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments x
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE x.SourceDocumentId = @Id
    ORDER BY Relation DESC, DocumentDate, Id;

    -- 6: charges of the invoice (kind PINV), of its landed cost adjustments (kind LCA) and, for an import, the charges of
    --    its containers (kind CNT, read-only: DocumentId = container, AdjustmentStatus = charge status) with ShareBase =
    --    the part that falls on this invoice's lines.
    SELECT c.Id, c.DocumentKind, c.DocumentId, SourceNumber = CASE WHEN c.DocumentKind = N'LCA' THEN lca.DocumentNumber ELSE d.DocumentNumber END,
           c.LineNumber, c.ChargeTypeId, ct.ChargeCode, ct.ChargeName, c.Description, c.ProviderPartyId, pp.PartyName AS ProviderName, c.Reference,
           c.CurrencyId, cur.CurrencyCode, c.RateType, c.ExchangeRate, c.Amount, c.AmountBase, c.AllocationMethod, c.IncludeInLandedCost, c.IncludedInSupplierInvoice, c.Notes,
           AllocatedBase = (SELECT SUM(AmountBase) FROM purchase.PurchaseChargeAllocations x WHERE x.ChargeId = c.Id),
           AdjustmentStatus = lca.Status,
           ContainerId = CAST(NULL AS INT), ContainerRef = CAST(NULL AS NVARCHAR(30)), ChargeDate = CAST(NULL AS DATE),
           ChargeStatus = CAST(NULL AS TINYINT), ShareBase = CAST(NULL AS DECIMAL(18,2))
    FROM purchase.PurchaseCharges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = c.CurrencyId
    LEFT  JOIN masterdata.Parties pp ON pp.Id = c.ProviderPartyId
    LEFT  JOIN purchase.PurchaseDocuments d ON d.Id = c.DocumentId AND c.DocumentKind = N'PINV'
    LEFT  JOIN purchase.LandedCostAdjustments lca ON lca.Id = c.DocumentId AND c.DocumentKind = N'LCA'
    WHERE (c.DocumentKind = N'PINV' AND c.DocumentId = @Id)
       OR (c.DocumentKind = N'LCA' AND lca.SourceInvoiceId = @Id)
    UNION ALL
    SELECT ch.Id, N'CNT', ch.ContainerId, cn.ContainerRef,
           CAST(ROW_NUMBER() OVER (ORDER BY cn.ContainerRef, ch.ChargeDate, ch.Id) AS INT),
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName, ch.Reference,
           ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase, ch.AllocationMethod, ch.IncludeInLandedCost,
           CAST(0 AS BIT), ch.Notes,
           ISNULL(s.Share, 0), ch.Status,
           ch.ContainerId, cn.ContainerRef, ch.ChargeDate, ch.Status, CAST(ISNULL(s.Share, 0) AS DECIMAL(18,2))
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers cn   ON cn.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    OUTER APPLY (SELECT Share = SUM(a.AmountBase * CAST(l.QuantityBase AS DECIMAL(18,6)) / NULLIF(cl.QuantityBase, 0))
                 FROM purchase.PurchaseDocumentLines l
                 INNER JOIN logistics.ContainerLines cl            ON cl.Id = l.ContainerLineId
                 INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id AND a.ChargeId = ch.Id
                 WHERE l.DocumentId = @Id) s
    WHERE ch.Status IN (1, 2)
      AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                  INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                  WHERE l.DocumentId = @Id AND cl.ContainerId = ch.ContainerId)
    ORDER BY 2, 3, 5;

    -- 7: containers of the document: for an order the containers carrying its lines, for an invoice its containers.
    SELECT ct.Id, ct.ContainerRef, ct.ContainerNo, ct.Status, ct.DispatchDate, ct.Eta, ct.OffloadedDate,
           ct.CurrentLocation, w.WarehouseCode, w.WarehouseName,
           AllocatedBase = ISNULL(x.Allocated, 0), ReceivedBase = ISNULL(x.Received, 0), InvoicedBase = ISNULL(x.Invoiced, 0),
           ct.ContainerTypeId, ctt.TypeCode AS ContainerTypeCode, ct.PurchaseOrderId
    FROM logistics.Containers ct
    INNER JOIN masterdata.ContainerTypes ctt ON ctt.Id = ct.ContainerTypeId
    LEFT  JOIN masterdata.Warehouses w       ON w.Id = ct.WarehouseId
    CROSS APPLY (SELECT Allocated = SUM(q.Allocated), Received = SUM(q.Received), Invoiced = SUM(q.Invoiced)
                 FROM (SELECT Allocated = cl.QuantityBase, Received = ISNULL(cl.ReceivedQuantityBase, 0),
                              Invoiced = ISNULL((SELECT SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                                                 INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                                                 WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (2, 4)), 0)
                       FROM logistics.ContainerLines cl
                       WHERE cl.ContainerId = ct.Id AND cl.PurchaseOrderId = @Id
                       UNION ALL
                       SELECT l.QuantityBase, l.ReceivedQuantityBase, l.QuantityBase
                       FROM purchase.PurchaseDocumentLines l
                       INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                       WHERE l.DocumentId = @Id AND cl.ContainerId = ct.Id) q) x
    WHERE ct.Status <> 8
      AND (EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = ct.Id AND cl.PurchaseOrderId = @Id)
           OR EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                      INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                      WHERE l.DocumentId = @Id AND cl.ContainerId = ct.Id))
    ORDER BY ct.ContainerRef;

    -- 8: approval requests and decisions (purchase orders).
    SELECT a.Id, a.RequestNo, a.ApproverUserId, u.FullName AS ApproverName, u.Email AS ApproverEmail,
           a.Status, a.ExpiresAtUtc, a.DecidedAtUtc, a.DecisionNote, a.Channel, a.RequestedAtUtc, ru.FullName AS RequestedByName
    FROM purchase.PurchaseOrderApprovals a
    INNER JOIN security.Users u ON u.Id = a.ApproverUserId
    LEFT  JOIN security.Users ru ON ru.Id = a.RequestedBy
    WHERE a.DocumentId = @Id
    ORDER BY a.RequestNo DESC, a.Id;
END
GO

/* ================================================================== 6. Order lines that can still be loaded */

-- Re-created (43) from the body of script 27: the lines of an invoice shipped in containers are not "invoiced directly".
CREATE OR ALTER PROCEDURE logistics.usp_Container_AvailablePoLines
    @PurchaseOrderId INT           = NULL,
    @SupplierId      INT           = NULL,
    @Search          NVARCHAR(100) = NULL,    -- order number, item code or name
    @ContainerId     INT           = NULL,
    @Top             INT           = 200
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @Top IS NULL OR @Top < 1 SET @Top = 200;

    SELECT TOP (@Top)
           d.Id AS PurchaseOrderId, d.DocumentNumber AS PurchaseOrderNumber, d.DocumentDate AS OrderDate, d.Status AS OrderStatus,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, cur.CurrencyCode, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           l.Id AS PoLineId, l.LineNumber AS PoLineNumber, l.ItemId, i.ItemCode, i.ItemName, i.Model, br.BrandName,
           l.ItemUnitId, ut.UnitTypeName, l.PackingFormula, l.Quantity AS OrderedQuantity,
           OrderedBase         = l.QuantityBase,
           InvoicedDirectBase  = ISNULL(dir.Qty, 0),
           LoadedElsewhereBase = ISNULL(oth.Qty, 0),
           LoadedHereBase      = ISNULL(here.Qty, 0),
           MaxHereBase         = l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0),
           AvailableBase       = l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) - ISNULL(here.Qty, 0),
           l.UnitPrice, l.DiscountPercent,
           UnitValueBase = l.LineTotal / d.ExchangeRate / NULLIF(l.QuantityBase, 0),
           ItemOilQtyPerUnit = i.OilQtyPerUnit,
           PcPerContainer = cnt.PackingFormula,
           i.WeightKg, i.VolumeCbm
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies cur    ON cur.Id = d.CurrencyId
    INNER JOIN masterdata.Warehouses w      ON w.Id = d.WarehouseId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN masterdata.Brands br         ON br.Id = i.BrandId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2) dir
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8 AND (@ContainerId IS NULL OR cl.ContainerId <> @ContainerId)) oth
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 WHERE cl.PoLineId = l.Id AND cl.ContainerId = @ContainerId) here
    OUTER APPLY (SELECT TOP (1) u.PackingFormula FROM inventory.ItemUnits u
                 INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
                 WHERE u.ItemId = l.ItemId AND t.IsContainer = 1) cnt
    WHERE dt.Code = N'PO' AND d.Status = 2
      AND (@PurchaseOrderId IS NULL OR d.Id = @PurchaseOrderId)
      AND (@SupplierId IS NULL OR d.SupplierId = @SupplierId)
      AND (@Search IS NULL OR d.DocumentNumber LIKE N'%' + @Search + N'%' OR i.ItemCode LIKE N'%' + @Search + N'%'
           OR i.ItemName LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%')
      AND (l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) - ISNULL(here.Qty, 0) > 0 OR ISNULL(here.Qty, 0) > 0)
    ORDER BY d.DocumentDate DESC, d.Id DESC, l.LineNumber;
END
GO

/* ================================================================== 7. Container_Save: for an invoice of the order */

-- Re-created (43) from the body of script 27: + @ForInvoiceId (default NULL = as before); invoices shipped in containers are not "invoiced directly".
CREATE OR ALTER PROCEDURE logistics.usp_Container_Save
    @Id                  INT            = NULL,   -- NULL = create (ContainerRef assigned now)
    @PurchaseOrderId     INT            = NULL,   -- required on create: the order the container is created from
    @ContainerNo         NVARCHAR(20)   = NULL,
    @ContainerTypeId     INT,
    @SealNo              NVARCHAR(30)   = NULL,
    @CustomsSealNo       NVARCHAR(30)   = NULL,
    @Description         NVARCHAR(500)  = NULL,
    @OrderDate           DATE,
    @ShippingMethod      NVARCHAR(10)   = N'Sea',
    @CountryOfOrigin     NCHAR(2)       = NULL,
    @ForwarderId         INT            = NULL,
    @TransporterId       INT            = NULL,
    @ShippingLine        NVARCHAR(100)  = NULL,
    @VesselName          NVARCHAR(100)  = NULL,
    @VoyageNo            NVARCHAR(30)   = NULL,
    @BookingNo           NVARCHAR(30)   = NULL,
    @PortOfLoadingId     INT            = NULL,
    @PortOfDestinationId INT            = NULL,
    @FinalDestinationId  INT            = NULL,
    @DispatchDate        DATE           = NULL,   -- the four milestone dates are replaced by the movements when there are some
    @Eta                 DATE           = NULL,
    @FreeDays            INT            = NULL,
    @GrossWeightKg       DECIMAL(18,3)  = NULL,
    @VolumeCbm           DECIMAL(18,3)  = NULL,
    @Packages            INT            = NULL,
    @BlNo                NVARCHAR(30)   = NULL,
    @BlDate              DATE           = NULL,
    @BlNotes             NVARCHAR(500)  = NULL,
    @MaxUnits            INT            = NULL,   -- NULL = the container type's capacity
    @BranchId            INT,
    @WarehouseId         INT            = NULL,
    @TruckNo             NVARCHAR(30)   = NULL,
    @WaybillNo           NVARCHAR(30)   = NULL,
    @DeclarationNo       NVARCHAR(30)   = NULL,
    @FeriNo              NVARCHAR(30)   = NULL,
    @ActualPortArrival   DATE           = NULL,
    @BorderCrossingDate  DATE           = NULL,
    @CustomsReleaseDate  DATE           = NULL,
    @StatusNote          NVARCHAR(200)  = NULL,
    @Notes               NVARCHAR(1000) = NULL,
    @Lines               logistics.tvp_ContainerLoadLine READONLY,
    @AllowOverCapacity   BIT            = 0,
    @RowVersion          BINARY(8)      = NULL,
    @UserId              INT            = NULL,
    @ForInvoiceId        INT            = NULL,   -- (43) for this invoice of the order: the order may be closed by it
    @NewId               INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ContainerNo = UPPER(NULLIF(LTRIM(RTRIM(@ContainerNo)), N''));
    SET @SealNo = NULLIF(LTRIM(RTRIM(@SealNo)), N'');
    SET @CustomsSealNo = NULLIF(LTRIM(RTRIM(@CustomsSealNo)), N'');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @ShippingMethod = NULLIF(LTRIM(RTRIM(@ShippingMethod)), N'');
    SET @BlNo = NULLIF(LTRIM(RTRIM(@BlNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @StatusNote = NULLIF(LTRIM(RTRIM(@StatusNote)), N'');
    IF @ShippingMethod IS NULL SET @ShippingMethod = N'Sea';

    IF @OrderDate IS NULL THROW 69000, 'Order date is required.', 1;
    IF @ShippingMethod NOT IN (N'Sea', N'Air', N'Road') THROW 69000, 'Shipping method must be Sea, Air or Road.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId AND IsActive = 1)
        THROW 69000, 'Container type not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 69000, 'Branch not found or inactive.', 1;
    IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1)
        THROW 69000, 'Offloading warehouse not found or inactive.', 1;
    IF @FreeDays IS NOT NULL AND @FreeDays < 0 THROW 69000, 'Free days cannot be negative.', 1;
    IF @MaxUnits IS NOT NULL AND @MaxUnits <= 0 THROW 69000, 'Maximum units must be greater than zero.', 1;
    IF @DispatchDate IS NOT NULL AND @Eta IS NOT NULL AND @Eta < @DispatchDate
        THROW 69000, 'The ETA cannot be earlier than the dispatch date.', 1;
    IF @ContainerNo IS NOT NULL AND EXISTS (SELECT 1 FROM logistics.Containers
                                            WHERE ContainerNo = @ContainerNo AND Status < 7 AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'Another open container already uses this container number.', 1;

    DECLARE @Status TINYINT = NULL;
    IF @Id IS NOT NULL
    BEGIN
        SELECT @Status = Status, @PurchaseOrderId = ISNULL(PurchaseOrderId, @PurchaseOrderId) FROM logistics.Containers WHERE Id = @Id;
        IF @Status IS NULL THROW 69006, 'Container not found.', 1;
        IF @Status >= 6 THROW 69005, 'An offloaded, closed or cancelled container can no longer be changed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
    END
    ELSE
    BEGIN
        IF @PurchaseOrderId IS NULL THROW 69000, 'The purchase order is required: a container is created from a purchase order.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                       WHERE d.Id = @PurchaseOrderId AND dt.Code = N'PO'
                         AND (d.Status = 2 OR (d.Status = 4 AND purchase.fn_PurchaseInvoice_TakesContainers(d.Id, @ForInvoiceId) = 1)))
            THROW 69000, 'The purchase order must be approved and still open.', 1;
    END

    DECLARE @Msg NVARCHAR(400);

    IF EXISTS (SELECT PoLineId FROM @Lines GROUP BY PoLineId HAVING COUNT(*) > 1)
        THROW 69000, 'The same order line appears twice in the container.', 1;

    -- Lines: order line of an approved order (lines already loaded may belong to an order closed since), quantity, oil.
    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN pol.Id IS NULL OR dt.Code <> N'PO' THEN N'the purchase order line no longer exists.'
             WHEN l.QuantityBase <= 0 THEN N'the quantity must be greater than zero.'
             WHEN l.OilQtyPerUnit < 0 THEN N'the oil quantity cannot be negative.'
             WHEN ex.Id IS NULL AND d.Status <> 2 AND NOT (d.Status = 4 AND purchase.fn_PurchaseInvoice_TakesContainers(d.Id, @ForInvoiceId) = 1) THEN N'order ' + ISNULL(d.DocumentNumber, N'(draft)') + N' is not approved or no longer open.'
             WHEN ex.Id IS NOT NULL AND d.Status NOT IN (2, 4) THEN N'order ' + ISNULL(d.DocumentNumber, N'(draft)') + N' was cancelled.'
             ELSE N'item ' + i.ItemCode + N' has no base unit.' END
    FROM @Lines l
    LEFT JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
    LEFT JOIN purchase.PurchaseDocuments d       ON d.Id = pol.DocumentId
    LEFT JOIN inventory.DocumentTypes dt         ON dt.Id = d.DocumentTypeId
    LEFT JOIN inventory.Items i                  ON i.Id = pol.ItemId
    LEFT JOIN logistics.ContainerLines ex        ON ex.ContainerId = @Id AND ex.PoLineId = l.PoLineId
    WHERE pol.Id IS NULL OR dt.Code <> N'PO' OR l.QuantityBase <= 0 OR l.OilQtyPerUnit < 0
       OR (ex.Id IS NULL AND d.Status <> 2 AND NOT (d.Status = 4 AND purchase.fn_PurchaseInvoice_TakesContainers(d.Id, @ForInvoiceId) = 1)) OR (ex.Id IS NOT NULL AND d.Status NOT IN (2, 4))
       OR NOT EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.ItemId = pol.ItemId AND u.IsBaseUnit = 1)
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

    -- Quantity still loadable on the order line.
    SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - '
                          + CAST(l.QuantityBase AS NVARCHAR(20)) + N' loaded but only '
                          + CAST(pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) AS NVARCHAR(20))
                          + N' remain on order ' + ISNULL(d.DocumentNumber, N'(draft)') + N' line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N'.'
    FROM @Lines l
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
    INNER JOIN purchase.PurchaseDocuments d       ON d.Id = pol.DocumentId
    INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = pol.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2) dir
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c2 ON c2.Id = cl.ContainerId
                 WHERE cl.PoLineId = pol.Id AND c2.Status <> 8 AND (@Id IS NULL OR cl.ContainerId <> @Id)) oth
    WHERE l.QuantityBase > pol.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0)
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 69008, @Msg, 1;

    IF @Id IS NOT NULL
    BEGIN
        -- Invoiced lines cannot be removed, nor loaded below what is invoiced.
        SELECT TOP (1) @Msg = N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - '
                              + CAST(q.Invoiced AS NVARCHAR(20)) + N' already invoiced (' + ISNULL(q.Numbers, N'') + N'); '
                              + CASE WHEN l.PoLineId IS NULL THEN N'the line cannot be removed.' ELSE N'the quantity cannot be lower.' END
        FROM logistics.ContainerLines cl
        INNER JOIN inventory.Items i ON i.Id = cl.ItemId
        CROSS APPLY (SELECT Invoiced = ISNULL(SUM(pil.QuantityBase), 0), Numbers = STRING_AGG(pd.DocumentNumber, N', ')
                     FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
        LEFT JOIN @Lines l ON l.PoLineId = cl.PoLineId
        WHERE cl.ContainerId = @Id AND q.Invoiced > 0 AND (l.PoLineId IS NULL OR l.QuantityBase < q.Invoiced)
        ORDER BY cl.LineNumber;
        IF @Msg IS NOT NULL THROW 69017, @Msg, 1;

        -- A removed line cannot carry a manual share of a posted charge.
        SELECT TOP (1) @Msg = N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' carries a manual share of the posted charge '
                              + t.ChargeName + N'. Cancel that charge before removing the line.'
        FROM logistics.ContainerLines cl
        INNER JOIN logistics.ContainerChargeAllocations a ON a.ContainerLineId = cl.Id AND a.IsManual = 1
        INNER JOIN logistics.ContainerCharges ch          ON ch.Id = a.ChargeId AND ch.Status = 2
        INNER JOIN purchase.ChargeTypes t                 ON t.Id = ch.ChargeTypeId
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId)
        ORDER BY cl.LineNumber;
        IF @Msg IS NOT NULL THROW 70014, @Msg, 1;
    END

    -- Capacity: a warning that the caller can override, never a hard block.
    DECLARE @Capacity INT = @MaxUnits;
    IF @Capacity IS NULL AND @Id IS NOT NULL SELECT @Capacity = MaxUnits FROM logistics.Containers WHERE Id = @Id;
    IF @Capacity IS NULL SELECT @Capacity = MaxUnits FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId;

    DECLARE @Allocated INT = ISNULL((SELECT SUM(QuantityBase) FROM @Lines), 0);
    IF @Capacity IS NOT NULL AND @Allocated > @Capacity AND ISNULL(@AllowOverCapacity, 0) = 0
    BEGIN
        SET @Msg = N'The container holds ' + CAST(@Capacity AS NVARCHAR(10)) + N' units and ' + CAST(@Allocated AS NVARCHAR(10))
                 + N' are loaded. Confirm to load it above its capacity.';
        THROW 69007, @Msg, 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Ref NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'CNT');
            EXEC inventory.usp_DocumentType_NextNumber N'CNT', @Ref OUTPUT, @BranchId;

            INSERT INTO logistics.Containers (DocumentTypeId, ContainerRef, PurchaseOrderId, ContainerNo, ContainerTypeId, SealNo, CustomsSealNo, Description,
                                              OrderDate, ShippingMethod, CountryOfOrigin, ForwarderId, TransporterId,
                                              ShippingLine, VesselName, VoyageNo, BookingNo, PortOfLoadingId, PortOfDestinationId, FinalDestinationId,
                                              DispatchDate, Eta, FreeDays, GrossWeightKg, VolumeCbm, Packages, BlNo, BlDate, BlNotes,
                                              MaxUnits, BranchId, WarehouseId, TruckNo, WaybillNo, DeclarationNo, FeriNo,
                                              ActualPortArrival, BorderCrossingDate, CustomsReleaseDate, StatusNote, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Ref, @PurchaseOrderId, @ContainerNo, @ContainerTypeId, @SealNo, @CustomsSealNo, @Description,
                    @OrderDate, @ShippingMethod, @CountryOfOrigin, @ForwarderId, @TransporterId,
                    @ShippingLine, @VesselName, @VoyageNo, @BookingNo, @PortOfLoadingId, @PortOfDestinationId, @FinalDestinationId,
                    @DispatchDate, @Eta, @FreeDays, @GrossWeightKg, @VolumeCbm, @Packages, @BlNo, @BlDate, @BlNotes,
                    @Capacity, @BranchId, @WarehouseId, @TruckNo, @WaybillNo, @DeclarationNo, @FeriNo,
                    @ActualPortArrival, @BorderCrossingDate, @CustomsReleaseDate, @StatusNote, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Id, N'Created', N'Draft ' + @Ref + ISNULL(N' from order ' + (SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @PurchaseOrderId), N''), @UserId);
        END
        ELSE
        BEGIN
            UPDATE logistics.Containers
            SET ContainerNo = @ContainerNo, ContainerTypeId = @ContainerTypeId, SealNo = @SealNo, CustomsSealNo = @CustomsSealNo,
                Description = @Description, OrderDate = @OrderDate, ShippingMethod = @ShippingMethod, CountryOfOrigin = @CountryOfOrigin,
                ForwarderId = @ForwarderId, TransporterId = @TransporterId, ShippingLine = @ShippingLine, VesselName = @VesselName,
                VoyageNo = @VoyageNo, BookingNo = @BookingNo, PortOfLoadingId = @PortOfLoadingId, PortOfDestinationId = @PortOfDestinationId,
                FinalDestinationId = @FinalDestinationId, DispatchDate = @DispatchDate, Eta = @Eta, FreeDays = @FreeDays,
                GrossWeightKg = @GrossWeightKg, VolumeCbm = @VolumeCbm, Packages = @Packages, BlNo = @BlNo, BlDate = @BlDate, BlNotes = @BlNotes,
                MaxUnits = @Capacity, BranchId = @BranchId, WarehouseId = @WarehouseId, TruckNo = @TruckNo, WaybillNo = @WaybillNo,
                DeclarationNo = @DeclarationNo, FeriNo = @FeriNo, ActualPortArrival = @ActualPortArrival,
                BorderCrossingDate = @BorderCrossingDate, CustomsReleaseDate = @CustomsReleaseDate, StatusNote = @StatusNote, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        -- Lines are kept per order line: removed ones go (with their charge shares), the others are updated, new ones added.
        -- Lines of CANCELLED invoices let go of the removed container lines.
        UPDATE pil SET ContainerLineId = NULL
        FROM purchase.PurchaseDocumentLines pil
        INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId AND pd.Status = 3
        INNER JOIN logistics.ContainerLines cl   ON cl.Id = pil.ContainerLineId
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId);

        DELETE a FROM logistics.ContainerChargeAllocations a
        INNER JOIN logistics.ContainerLines cl ON cl.Id = a.ContainerLineId
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId);

        DELETE cl FROM logistics.ContainerLines cl
        WHERE cl.ContainerId = @Id AND NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.PoLineId = cl.PoLineId);

        UPDATE cl
        SET LineNumber = l.LineNumber, Quantity = l.QuantityBase, OilIncluded = ISNULL(l.OilIncluded, 0),
            OilQtyPerUnit = CASE WHEN ISNULL(l.OilIncluded, 0) = 1 THEN ISNULL(l.OilQtyPerUnit, i.OilQtyPerUnit) END,
            Notes = NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM logistics.ContainerLines cl
        INNER JOIN @Lines l          ON l.PoLineId = cl.PoLineId
        INNER JOIN inventory.Items i ON i.Id = cl.ItemId
        WHERE cl.ContainerId = @Id;

        INSERT INTO logistics.ContainerLines (ContainerId, LineNumber, PurchaseOrderId, PoLineId, ItemId, ItemUnitId, PackingFormula,
                                              Quantity, OilIncluded, OilQtyPerUnit, Notes)
        SELECT @Id, l.LineNumber, pol.DocumentId, pol.Id, pol.ItemId, bu.Id, 1, l.QuantityBase, ISNULL(l.OilIncluded, 0),
               CASE WHEN ISNULL(l.OilIncluded, 0) = 1 THEN ISNULL(l.OilQtyPerUnit, i.OilQtyPerUnit) END,
               NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM @Lines l
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = l.PoLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        CROSS APPLY (SELECT TOP (1) u.Id FROM inventory.ItemUnits u WHERE u.ItemId = pol.ItemId AND u.IsBaseUnit = 1 ORDER BY u.Id) bu
        WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = @Id AND cl.PoLineId = l.PoLineId);

        EXEC logistics.usp_Container_ReallocateCharges @Id;
        EXEC logistics.usp_Container_RefreshStatus @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 8. PlanFromOrder: for an invoice of the order */

-- Re-created (43) from the body of script 28: + @ForInvoiceId (default NULL = as before) plans only what that invoice has outside containers.
CREATE OR ALTER PROCEDURE logistics.usp_Container_PlanFromOrder
    @PurchaseOrderId INT,
    @ContainerTypeId INT,
    @MixRemainders   BIT = 1,       -- 0 = the rest of every order line gets its own container
    @Capacities      logistics.tvp_ItemCapacity READONLY,    -- pieces per container typed by the user (optional)
    @ForInvoiceId    INT = NULL      -- (43) only what this invoice of the order has outside containers
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                   WHERE d.Id = @PurchaseOrderId AND dt.Code = N'PO'
                     AND (d.Status = 2 OR (d.Status = 4 AND purchase.fn_PurchaseInvoice_TakesContainers(d.Id, @ForInvoiceId) = 1)))
        THROW 69000, 'The purchase order must be approved and still open.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId AND IsActive = 1)
        THROW 69000, 'Container type not found or inactive.', 1;
    IF EXISTS (SELECT 1 FROM @Capacities WHERE PcsPerContainer <= 0)
        THROW 69000, 'Pieces per container must be greater than zero.', 1;

    DECLARE @TypeCap INT = (SELECT MaxUnits FROM masterdata.ContainerTypes WHERE Id = @ContainerTypeId);
    DECLARE @Msg NVARCHAR(400);

    -- order lines: what can still be loaded (ordered - invoiced without container - loaded in other containers)
    DECLARE @Lines TABLE
    (
        PoLineId      INT          NOT NULL PRIMARY KEY,
        PoLineNumber  INT          NOT NULL,
        ItemId        INT          NOT NULL,
        OrderedBase   INT          NOT NULL,
        AvailableBase INT          NOT NULL,
        Cap           INT          NULL,
        CapSource     NVARCHAR(10) NOT NULL,     -- Entered | Item | Type | None
        OilIncluded   BIT          NOT NULL,
        Remaining     INT          NOT NULL
    );
    INSERT INTO @Lines (PoLineId, PoLineNumber, ItemId, OrderedBase, AvailableBase, Cap, CapSource, OilIncluded, Remaining)
    SELECT l.Id, l.LineNumber, l.ItemId, l.QuantityBase,
           CASE WHEN @ForInvoiceId IS NOT NULL AND inv.UnlinkedBase < l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0)
                THEN inv.UnlinkedBase
                ELSE l.QuantityBase - ISNULL(dir.Qty, 0) - ISNULL(oth.Qty, 0) END,
           COALESCE(cap.PcsPerContainer, NULLIF(cnt.PackingFormula, 0), @TypeCap),
           CASE WHEN cap.PcsPerContainer IS NOT NULL THEN N'Entered'
                WHEN cnt.PackingFormula > 0 THEN N'Item'
                WHEN @TypeCap IS NOT NULL THEN N'Type'
                ELSE N'None' END,
           CASE WHEN i.OilQtyPerUnit > 0 THEN 1 ELSE 0 END,
           0
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    LEFT  JOIN @Capacities cap   ON cap.ItemId = l.ItemId
    LEFT  JOIN purchase.fn_PurchaseInvoice_Unlinked(@ForInvoiceId) inv ON inv.PoLineId = l.Id
    OUTER APPLY (SELECT Qty = SUM(x.QuantityBase) FROM purchase.PurchaseDocumentLines x
                 INNER JOIN purchase.PurchaseDocuments xd ON xd.Id = x.DocumentId
                 WHERE x.SourceLineId = l.Id AND x.ContainerLineId IS NULL AND xd.Status IN (1, 2, 4) AND xd.ReceiptMode <> 2) dir
    OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                 INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                 WHERE cl.PoLineId = l.Id AND c.Status <> 8) oth
    OUTER APPLY (SELECT TOP (1) u.PackingFormula FROM inventory.ItemUnits u
                 INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
                 WHERE u.ItemId = l.ItemId AND t.IsContainer = 1
                 ORDER BY u.Id) cnt
    WHERE l.DocumentId = @PurchaseOrderId AND (@ForInvoiceId IS NULL OR inv.UnlinkedBase > 0);

    SELECT TOP (1) @Msg = N'Line ' + CAST(l.PoLineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): the number of pieces per container '
                        + N'is unknown. Enter it, or give the item a Container unit or the container type a capacity.'
    FROM @Lines l INNER JOIN inventory.Items i ON i.Id = l.ItemId
    WHERE l.AvailableBase > 0 AND l.Cap IS NULL
    ORDER BY l.PoLineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

    IF (SELECT SUM(AvailableBase / Cap) FROM @Lines WHERE AvailableBase > 0) > 200
        THROW 69000, 'The plan would need more than 200 containers. Check the pieces per container, or plan the order in parts.', 1;

    DECLARE @Plan TABLE (Seq INT NOT NULL, PoLineId INT NOT NULL, QuantityBase INT NOT NULL, PRIMARY KEY (Seq, PoLineId));
    DECLARE @Seq INT = 0, @PoLineId INT, @Avail INT, @Cap INT, @Full INT, @k INT, @Rem INT;

    -- a. whole containers of one item
    DECLARE full_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
        SELECT PoLineId, AvailableBase, Cap FROM @Lines WHERE AvailableBase > 0 ORDER BY PoLineNumber;
    OPEN full_cur;
    FETCH NEXT FROM full_cur INTO @PoLineId, @Avail, @Cap;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Full = @Avail / @Cap;
        SET @k = 0;
        WHILE @k < @Full
        BEGIN
            SET @k = @k + 1;
            SET @Seq = @Seq + 1;
            INSERT INTO @Plan (Seq, PoLineId, QuantityBase) VALUES (@Seq, @PoLineId, @Cap);
        END
        UPDATE @Lines SET Remaining = @Avail - @Full * @Cap WHERE PoLineId = @PoLineId;
        FETCH NEXT FROM full_cur INTO @PoLineId, @Avail, @Cap;
    END
    CLOSE full_cur;
    DEALLOCATE full_cur;

    -- b. the rest of every line
    DECLARE @FirstRest INT = @Seq;
    IF ISNULL(@MixRemainders, 1) = 0
    BEGIN
        INSERT INTO @Plan (Seq, PoLineId, QuantityBase)
        SELECT @FirstRest + ROW_NUMBER() OVER (ORDER BY PoLineNumber), PoLineId, Remaining
        FROM @Lines WHERE Remaining > 0;
    END
    ELSE
    BEGIN
        DECLARE @Bins TABLE (Seq INT NOT NULL PRIMARY KEY, Used DECIMAL(38,20) NOT NULL);
        DECLARE @RestA TABLE (Seq INT NOT NULL, PoLineId INT NOT NULL, QuantityBase INT NOT NULL, PRIMARY KEY (Seq, PoLineId));
        DECLARE @RestB TABLE (Seq INT NOT NULL, PoLineId INT NOT NULL, QuantityBase INT NOT NULL, PRIMARY KEY (Seq, PoLineId));
        DECLARE @Frac DECIMAL(38,20), @Bin INT, @Need INT;

        -- first fit, largest first, a line is never cut
        DECLARE ffd_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT PoLineId, Remaining, Cap FROM @Lines WHERE Remaining > 0
            ORDER BY CAST(Remaining AS DECIMAL(38,20)) / Cap DESC, PoLineNumber;
        OPEN ffd_cur;
        FETCH NEXT FROM ffd_cur INTO @PoLineId, @Rem, @Cap;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Frac = CAST(@Rem AS DECIMAL(38,20)) / @Cap;
            SET @Bin = NULL;
            SELECT TOP (1) @Bin = Seq FROM @Bins WHERE Used + @Frac <= 1.000001 ORDER BY Seq;
            IF @Bin IS NULL
            BEGIN
                SET @Bin = @FirstRest + 1 + (SELECT COUNT(*) FROM @Bins);
                INSERT INTO @Bins (Seq, Used) VALUES (@Bin, 0);
            END
            UPDATE @Bins SET Used = Used + @Frac WHERE Seq = @Bin;
            INSERT INTO @RestA (Seq, PoLineId, QuantityBase) VALUES (@Bin, @PoLineId, @Rem);
            FETCH NEXT FROM ffd_cur INTO @PoLineId, @Rem, @Cap;
        END
        CLOSE ffd_cur;
        DEALLOCATE ffd_cur;

        SET @Need = CEILING((SELECT SUM(CAST(Remaining AS DECIMAL(38,20)) / Cap) FROM @Lines WHERE Remaining > 0) - 0.000001);

        IF (SELECT COUNT(*) FROM @Bins) > @Need
        BEGIN
            -- cutting lines saves containers: fill every container to the brim, a line goes on in the next container
            DECLARE @Used DECIMAL(38,20) = 0, @Open BIT = 0, @Fits INT, @Take INT, @SeqB INT = @FirstRest;
            DECLARE nf_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
                SELECT PoLineId, Remaining, Cap FROM @Lines WHERE Remaining > 0
                ORDER BY CAST(Remaining AS DECIMAL(38,20)) / Cap DESC, PoLineNumber;
            OPEN nf_cur;
            FETCH NEXT FROM nf_cur INTO @PoLineId, @Rem, @Cap;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                WHILE @Rem > 0
                BEGIN
                    IF @Open = 0
                    BEGIN
                        SET @SeqB = @SeqB + 1;
                        SET @Used = 0;
                        SET @Open = 1;
                    END
                    SET @Fits = FLOOR((1 - @Used) * @Cap + 0.000001);
                    IF @Fits <= 0
                        SET @Open = 0;
                    ELSE
                    BEGIN
                        SET @Take = CASE WHEN @Rem < @Fits THEN @Rem ELSE @Fits END;
                        INSERT INTO @RestB (Seq, PoLineId, QuantityBase) VALUES (@SeqB, @PoLineId, @Take);
                        SET @Used = @Used + CAST(@Take AS DECIMAL(38,20)) / @Cap;
                        SET @Rem = @Rem - @Take;
                        IF @Rem > 0 OR @Used >= 0.999999 SET @Open = 0;   -- a cut line goes on in the next container
                    END
                END
                FETCH NEXT FROM nf_cur INTO @PoLineId, @Rem, @Cap;
            END
            CLOSE nf_cur;
            DEALLOCATE nf_cur;
        END

        IF EXISTS (SELECT 1 FROM @RestB) AND (SELECT COUNT(DISTINCT Seq) FROM @RestB) < (SELECT COUNT(*) FROM @Bins)
            INSERT INTO @Plan (Seq, PoLineId, QuantityBase) SELECT Seq, PoLineId, QuantityBase FROM @RestB;
        ELSE
            INSERT INTO @Plan (Seq, PoLineId, QuantityBase) SELECT Seq, PoLineId, QuantityBase FROM @RestA;
    END

    IF (SELECT COUNT(DISTINCT Seq) FROM @Plan) > 200
        THROW 69000, 'The plan would need more than 200 containers. Check the pieces per container, or plan the order in parts.', 1;

    -- 1: containers. MaxUnits = equivalent capacity in pieces; a container full within 0.0001 % counts as full
    --    (the same rule as usp_Container_CreateBatch, so an unedited plan never raises the capacity warning).
    SELECT x.Seq, x.ItemCount, x.Units,
           FillPct  = CAST(ROUND(100 * x.Fill, 1) AS DECIMAL(9,1)),
           MaxUnits = CASE WHEN x.Fill <= 1.000001 AND FLOOR(x.Units / x.Fill + 0.000001) < x.Units THEN x.Units
                           ELSE CAST(FLOOR(x.Units / x.Fill + 0.000001) AS INT) END,
           ItemSummary = CASE WHEN x.ItemCount = 1 THEN x.FirstItem ELSE N'Mixed - ' + CAST(x.ItemCount AS NVARCHAR(10)) + N' items' END
    FROM (SELECT p.Seq,
                 ItemCount = COUNT(DISTINCT l.ItemId),
                 Units     = SUM(p.QuantityBase),
                 Fill      = SUM(CAST(p.QuantityBase AS DECIMAL(38,20)) / l.Cap),
                 FirstItem = MIN(i.ItemCode)
          FROM @Plan p
          INNER JOIN @Lines l          ON l.PoLineId = p.PoLineId
          INNER JOIN inventory.Items i ON i.Id = l.ItemId
          GROUP BY p.Seq) x
    ORDER BY x.Seq;

    -- 2: lines of every container
    SELECT p.Seq,
           LineNumber = ROW_NUMBER() OVER (PARTITION BY p.Seq ORDER BY l.PoLineNumber),
           p.PoLineId, l.PoLineNumber, l.ItemId, i.ItemCode, i.ItemName, i.Model, p.QuantityBase,
           PcsPerContainer = l.Cap, l.OilIncluded, i.OilQtyPerUnit
    FROM @Plan p
    INNER JOIN @Lines l          ON l.PoLineId = p.PoLineId
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    ORDER BY p.Seq, l.PoLineNumber;

    -- 3: order lines
    SELECT l.PoLineId, l.PoLineNumber, l.ItemId, i.ItemCode, i.ItemName, i.Model,
           l.OrderedBase,
           AvailableBase    = CASE WHEN l.AvailableBase > 0 THEN l.AvailableBase ELSE 0 END,
           PlannedBase      = ISNULL(pl.Qty, 0),
           PcsPerContainer  = l.Cap,
           CapacitySource   = l.CapSource,
           ContainersNeeded = CAST(CASE WHEN l.AvailableBase > 0 THEN CAST(l.AvailableBase AS DECIMAL(19,4)) / NULLIF(l.Cap, 0) ELSE 0 END AS DECIMAL(9,2)),
           l.OilIncluded
    FROM @Lines l
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    OUTER APPLY (SELECT Qty = SUM(p.QuantityBase) FROM @Plan p WHERE p.PoLineId = l.PoLineId) pl
    ORDER BY l.PoLineNumber;
END
GO

/* ================================================================== 9. CreateBatch: for an invoice of the order */

-- Re-created (43) from the body of script 28: + @ForInvoiceId (default NULL = as before), passed to usp_Container_Save.
CREATE OR ALTER PROCEDURE logistics.usp_Container_CreateBatch
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

/* ================================================================== 10. The containers of an invoice: summary */

-- Two result sets: 1 per item of the invoice (what it needs in containers and what is linked), 2 per linked container.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseInvoice_ContainerSummary
    @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.ItemId, i.ItemCode, i.ItemName, s.InvoicedBase, s.PcsPerContainer,
           ContainersNeeded = CAST(CAST(s.InvoicedBase AS DECIMAL(19,4)) / s.PcsPerContainer AS DECIMAL(18,2)),
           FullContainers   = s.InvoicedBase / s.PcsPerContainer,
           PartialPieces    = s.InvoicedBase % s.PcsPerContainer,
           s.LinkedBase, s.ContainersLinked, s.UnlinkedBase
    FROM purchase.fn_PurchaseInvoice_ItemContainers(@InvoiceId) s
    INNER JOIN inventory.Items i ON i.Id = s.ItemId
    ORDER BY i.ItemCode;

    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, c.Status, cl.ItemId, i.ItemCode,
           QuantityBase        = SUM(l.QuantityBase),
           MaxUnits            = COALESCE(c.MaxUnits, ct.MaxUnits),
           ShareOfContainerPct = CAST(100.0 * SUM(l.QuantityBase) / NULLIF(COALESCE(c.MaxUnits, ct.MaxUnits), 0) AS DECIMAL(9,2)),
           CanUnlink           = CAST(CASE WHEN c.Status IN (1, 2) THEN 1 ELSE 0 END AS BIT)
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN logistics.ContainerLines cl   ON cl.Id = l.ContainerLineId
    INNER JOIN logistics.Containers c        ON c.Id = cl.ContainerId
    INNER JOIN masterdata.ContainerTypes ct  ON ct.Id = c.ContainerTypeId
    INNER JOIN inventory.Items i             ON i.Id = cl.ItemId
    WHERE l.DocumentId = @InvoiceId
    GROUP BY c.Id, c.ContainerRef, c.ContainerNo, c.Status, cl.ItemId, i.ItemCode, c.MaxUnits, ct.MaxUnits
    ORDER BY c.ContainerRef, i.ItemCode;
END
GO

/* ================================================================== 11. Link candidates */

-- The container lines an invoice can be linked to: containers of its purchase order still Draft or Confirmed, lines of
-- the order lines the invoice still has pieces of outside any container, with something loaded and not yet invoiced
-- (by any invoice that is not cancelled). UnlinkedBase = what the invoice has of that order line outside containers.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseInvoice_LinkCandidates
    @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OrderId INT = (SELECT d.SourceDocumentId FROM purchase.PurchaseDocuments d
                            INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                            WHERE d.Id = @InvoiceId AND dt.Code = N'PINV' AND d.Status IN (1, 2));

    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS ContainerStatus,
           cl.Id AS ContainerLineId, cl.LineNumber AS ContainerLineNumber, cl.PoLineId, cl.ItemId, i.ItemCode, i.ItemName,
           LoadedBase    = cl.QuantityBase,
           InvoicedBase  = ISNULL(q.Qty, 0),
           AvailableBase = cl.QuantityBase - ISNULL(q.Qty, 0),
           u.UnlinkedBase
    FROM logistics.ContainerLines cl
    INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
    INNER JOIN inventory.Items i      ON i.Id = cl.ItemId
    INNER JOIN purchase.fn_PurchaseInvoice_Unlinked(@InvoiceId) u ON u.PoLineId = cl.PoLineId
    OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
    WHERE cl.PurchaseOrderId = @OrderId AND c.Status IN (1, 2) AND cl.QuantityBase - ISNULL(q.Qty, 0) > 0
    ORDER BY c.ContainerRef, cl.LineNumber;
END
GO

/* ================================================================== 12. Link an invoice to container lines */

-- A draft, or a posted invoice shipped in containers (receipt mode 2), takes container lines of its own order. Its
-- lines of that order line outside containers are SPLIT: the linked part becomes a line of its own (same item, unit,
-- price, discount, warehouse), the rest stays unlinked. A part that is not a whole number of the line's unit is put in
-- the base unit (price per base unit), as usp_PurchaseDocument_CreateFromSource does. The document total is kept: a
-- rounding difference goes on the last line split. A draft still received on posting becomes "shipped in containers".
-- Nothing else needs writing: the order lines count invoiced quantities by the invoice lines, and
-- logistics.ContainerInvoices is the unused table of the old model (script 27).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseInvoice_LinkContainers
    @InvoiceId  INT,
    @RowVersion BINARY(8) = NULL,
    @Links      logistics.tvp_ContainerLineQty READONLY,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @TypeCode NVARCHAR(20), @Status TINYINT, @OrderId INT, @Mode TINYINT, @Number NVARCHAR(30);
        SELECT @TypeCode = dt.Code, @Status = d.Status, @OrderId = d.SourceDocumentId, @Mode = d.ReceiptMode,
               @Number = ISNULL(d.DocumentNumber, N'draft #' + CAST(d.Id AS NVARCHAR(10)))
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @InvoiceId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PINV' OR @OrderId IS NULL
            THROW 65028, 'Only a purchase invoice created from a purchase order can be linked to containers.', 1;
        IF @Status NOT IN (1, 2) THROW 65010, 'A cancelled invoice cannot be linked to containers.', 1;
        IF @Status = 2 AND @Mode <> 2
            THROW 65028, 'This invoice was received when it was posted: it cannot be linked to containers.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM @Links) THROW 65000, 'Choose at least one container line to link.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @InvoiceId)
            THROW 65020, 'This invoice has its own charges. Remove them: the charges of an import are entered on its containers.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE SourceInvoiceId = @InvoiceId AND Status <> 3)
            THROW 65028, 'This invoice has a landed cost adjustment: cancel or delete it before linking the invoice to containers.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments r WHERE r.SourceDocumentId = @InvoiceId AND r.Status <> 3)
            THROW 65028, 'This invoice has purchase returns: it can no longer be linked to containers.', 1;

        DECLARE @Msg NVARCHAR(400);

        -- the containers: still Draft or Confirmed
        SELECT TOP (1) @Msg = CASE WHEN c.Status = 8 THEN N'Container ' + c.ContainerRef + N' is cancelled.'
                                   ELSE N'Container ' + c.ContainerRef + N' has started moving: it can no longer be linked.' END
        FROM @Links k
        INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
        INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        WHERE c.Status NOT IN (1, 2)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 65027, @Msg, 1;

        -- the lines: of this order, a quantity, within what is loaded and not yet invoiced
        SELECT TOP (1) @Msg =
            CASE WHEN cl.Id IS NULL THEN N'A container line to link no longer exists.'
                 WHEN cl.PurchaseOrderId <> @OrderId THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10))
                      + N' belongs to another purchase order.'
                 WHEN k.QuantityBase <= 0 THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10))
                      + N': the quantity must be greater than zero.'
                 ELSE N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): '
                      + CAST(k.QuantityBase AS NVARCHAR(20)) + N' to link but only ' + CAST(cl.QuantityBase - ISNULL(q.Qty, 0) AS NVARCHAR(20))
                      + N' are loaded and not yet invoiced.' END
        FROM @Links k
        LEFT JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
        LEFT JOIN logistics.Containers c      ON c.Id = cl.ContainerId
        LEFT JOIN inventory.Items i           ON i.Id = cl.ItemId
        OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
        WHERE cl.Id IS NULL OR cl.PurchaseOrderId <> @OrderId OR k.QuantityBase <= 0
           OR k.QuantityBase > cl.QuantityBase - ISNULL(q.Qty, 0)
        ORDER BY c.ContainerRef, cl.LineNumber;
        IF @Msg IS NOT NULL THROW 65019, @Msg, 1;

        -- the invoice: within its pieces of that order line outside containers
        SELECT TOP (1) @Msg = i.ItemCode + N': ' + CAST(t.Qty AS NVARCHAR(20)) + N' pieces to link but only '
                              + CAST(ISNULL(u.UnlinkedBase, 0) AS NVARCHAR(20)) + N' of this invoice (order line '
                              + CAST(pol.LineNumber AS NVARCHAR(10)) + N') are not in a container yet.'
        FROM (SELECT cl.PoLineId, Qty = SUM(k.QuantityBase) FROM @Links k
              INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId GROUP BY cl.PoLineId) t
        INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = t.PoLineId
        INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
        LEFT  JOIN purchase.fn_PurchaseInvoice_Unlinked(@InvoiceId) u ON u.PoLineId = t.PoLineId
        WHERE t.Qty > ISNULL(u.UnlinkedBase, 0)
        ORDER BY pol.LineNumber;
        IF @Msg IS NOT NULL THROW 65019, @Msg, 1;

        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines
                   WHERE DocumentId = @InvoiceId AND ContainerLineId IS NULL AND (ReceivedQuantityBase > 0 OR ReturnedQuantityBase > 0))
            THROW 65028, 'Goods of this invoice outside containers were already received or returned: it can no longer be linked.', 1;

        DECLARE @OldTotal DECIMAL(18,2) = (SELECT ISNULL(SUM(LineTotal), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        DECLARE @NextNo INT = (SELECT ISNULL(MAX(LineNumber), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        DECLARE @Cl INT, @PoLineId INT, @Need INT, @LineId INT, @Have INT, @Pf INT, @ItemId INT, @BaseUnit INT, @LastLine INT;

        DECLARE links CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT k.ContainerLineId, cl.PoLineId, k.QuantityBase
            FROM @Links k
            INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
            INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
            ORDER BY c.ContainerRef, cl.LineNumber;
        OPEN links;
        FETCH NEXT FROM links INTO @Cl, @PoLineId, @Need;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            WHILE @Need > 0
            BEGIN
                SET @LineId = NULL;
                SELECT TOP (1) @LineId = Id, @Have = QuantityBase, @Pf = PackingFormula, @ItemId = ItemId
                FROM purchase.PurchaseDocumentLines
                WHERE DocumentId = @InvoiceId AND ContainerLineId IS NULL AND SourceLineId = @PoLineId AND QuantityBase > 0
                ORDER BY LineNumber;
                IF @LineId IS NULL THROW 65019, 'The invoice has no more pieces of that order line outside containers.', 1;

                IF @Have <= @Need
                BEGIN
                    -- the whole line goes into the container
                    UPDATE purchase.PurchaseDocumentLines SET ContainerLineId = @Cl WHERE Id = @LineId;
                    SET @Need -= @Have;
                    SET @LastLine = @LineId;
                END
                ELSE
                BEGIN
                    SET @BaseUnit = (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = @ItemId AND IsBaseUnit = 1 ORDER BY Id);
                    IF @BaseUnit IS NULL AND (@Need % @Pf <> 0 OR (@Have - @Need) % @Pf <> 0)
                        THROW 65028, 'The item of a line to split has no base unit.', 1;

                    -- the linked part: a new line
                    SET @NextNo += 1;
                    INSERT INTO purchase.PurchaseDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                                                UnitPrice, DiscountPercent, UnitCostBase, ReceivedQuantityBase, ReturnedQuantityBase,
                                                                ImportRowNumber, Notes, SourceLineId, ShippedQuantityBase, FobCostBase, AllocatedChargesBase,
                                                                ContainerLineId)
                    SELECT @InvoiceId, @NextNo, l.ItemId,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN l.ItemUnitId ELSE @BaseUnit END,
                           l.WarehouseId, l.ExpiryDate,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN @Need / l.PackingFormula ELSE @Need END,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN l.PackingFormula ELSE 1 END,
                           CASE WHEN @Need % l.PackingFormula = 0 THEN l.UnitPrice ELSE ROUND(l.UnitPrice / l.PackingFormula, 4) END,
                           l.DiscountPercent, l.UnitCostBase, 0, 0, l.ImportRowNumber, l.Notes, l.SourceLineId, 0, l.FobCostBase, 0, @Cl
                    FROM purchase.PurchaseDocumentLines l
                    WHERE l.Id = @LineId;

                    -- the rest stays where it was, unlinked (it keeps its id: what refers to the line still finds it)
                    UPDATE purchase.PurchaseDocumentLines
                    SET ItemUnitId     = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN ItemUnitId ELSE @BaseUnit END,
                        Quantity       = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN (@Have - @Need) / PackingFormula ELSE @Have - @Need END,
                        UnitPrice      = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN UnitPrice ELSE ROUND(UnitPrice / PackingFormula, 4) END,
                        PackingFormula = CASE WHEN (@Have - @Need) % PackingFormula = 0 THEN PackingFormula ELSE 1 END
                    WHERE Id = @LineId;

                    SET @Need = 0;
                    SET @LastLine = @LineId;
                END
            END
            FETCH NEXT FROM links INTO @Cl, @PoLineId, @Need;
        END
        CLOSE links;
        DEALLOCATE links;

        -- the lines of every container first, by container, then what is not in a container yet
        UPDATE l SET LineNumber = x.Seq
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN (SELECT pl.Id, Seq = ROW_NUMBER() OVER (ORDER BY CASE WHEN pl.ContainerLineId IS NULL THEN 1 ELSE 0 END,
                                                                    c.ContainerRef, cl.LineNumber, pl.LineNumber, pl.Id)
                    FROM purchase.PurchaseDocumentLines pl
                    LEFT JOIN logistics.ContainerLines cl ON cl.Id = pl.ContainerLineId
                    LEFT JOIN logistics.Containers c      ON c.Id = cl.ContainerId
                    WHERE pl.DocumentId = @InvoiceId) x ON x.Id = l.Id
        WHERE l.LineNumber <> x.Seq;

        -- the document total does not change: a rounding difference goes on the last line split
        DECLARE @Diff DECIMAL(18,2) = @OldTotal - (SELECT ISNULL(SUM(LineTotal), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        IF @Diff <> 0 AND @LastLine IS NOT NULL
            UPDATE purchase.PurchaseDocumentLines
            SET UnitPrice = ROUND(UnitPrice + @Diff / NULLIF(Quantity * (1 - DiscountPercent / 100.0), 0), 4)
            WHERE Id = @LastLine;

        UPDATE d
        SET ReceiptMode = 2,
            TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / d.ExchangeRate, 2), TotalLandedCostBase = ROUND(x.Amt / d.ExchangeRate, 2) + d.TotalChargesBase,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId) x
        WHERE d.Id = @InvoiceId;

        -- the value basis of the container charges follows the invoice, and both sides keep the history
        DECLARE @Cid INT, @Ref NVARCHAR(30), @Qty INT;
        DECLARE cts CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
            SELECT cl.ContainerId, c.ContainerRef, SUM(k.QuantityBase)
            FROM @Links k
            INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
            INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
            GROUP BY cl.ContainerId, c.ContainerRef
            ORDER BY c.ContainerRef;
        OPEN cts;
        FETCH NEXT FROM cts INTO @Cid, @Ref, @Qty;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_ReallocateCharges @Cid, 1, 1;
            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            VALUES (@Cid, N'Updated', N'Linked to purchase invoice ' + @Number + N': ' + CAST(@Qty AS NVARCHAR(20)) + N' pieces', @UserId);
            FETCH NEXT FROM cts INTO @Cid, @Ref, @Qty;
        END
        CLOSE cts;
        DEALLOCATE cts;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        SELECT @InvoiceId, N'Updated',
               LEFT(N'Linked to containers ' + STRING_AGG(x.Ref + N' (' + CAST(x.Qty AS NVARCHAR(20)) + N')', N', ')
                    WITHIN GROUP (ORDER BY x.Ref), 1000), @UserId
        FROM (SELECT Ref = c.ContainerRef, Qty = SUM(k.QuantityBase)
              FROM @Links k
              INNER JOIN logistics.ContainerLines cl ON cl.Id = k.ContainerLineId
              INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId
              GROUP BY c.ContainerRef) x;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseInvoice_ContainerSummary @InvoiceId;
END
GO

/* ================================================================== 13. Unlink an invoice from a container */

-- The container must still be Draft or Confirmed (nothing received). The invoice lines on it lose their container and
-- go back into the unlinked line of the same order line, item, unit, price, discount, warehouse and expiry when there
-- is one (otherwise they stay as separate unlinked lines). The invoice stays "shipped in containers".
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseInvoice_UnlinkContainer
    @InvoiceId   INT,
    @ContainerId INT,
    @RowVersion  BINARY(8) = NULL,
    @UserId      INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @TypeCode NVARCHAR(20), @Status TINYINT, @Number NVARCHAR(30);
        SELECT @TypeCode = dt.Code, @Status = d.Status, @Number = ISNULL(d.DocumentNumber, N'draft #' + CAST(d.Id AS NVARCHAR(10)))
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @InvoiceId;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @TypeCode <> N'PINV' THROW 65028, 'Only a purchase invoice can be unlinked from a container.', 1;
        IF @Status NOT IN (1, 2) THROW 65010, 'A cancelled invoice cannot be changed.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

        DECLARE @Ref NVARCHAR(30), @CStatus TINYINT, @Msg NVARCHAR(400);
        SELECT @Ref = ContainerRef, @CStatus = Status FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @ContainerId;
        IF @Ref IS NULL OR NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l
                                       INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
                                       WHERE l.DocumentId = @InvoiceId AND cl.ContainerId = @ContainerId)
        BEGIN
            SET @Msg = N'Container ' + ISNULL(@Ref, N'#' + CAST(@ContainerId AS NVARCHAR(10))) + N' is not linked to this invoice.';
            THROW 65019, @Msg, 1;
        END
        IF @CStatus NOT IN (1, 2) OR EXISTS (SELECT 1 FROM logistics.ContainerLines WHERE ContainerId = @ContainerId AND ISNULL(ReceivedQuantityBase, 0) > 0)
        BEGIN
            SET @Msg = N'Container ' + @Ref + N' has started moving: it can no longer be unlinked.';
            THROW 65027, @Msg, 1;
        END

        DECLARE @OldTotal DECIMAL(18,2) = (SELECT ISNULL(SUM(LineTotal), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        DECLARE @Pieces INT;

        DECLARE @Freed TABLE (Id INT PRIMARY KEY);
        UPDATE l SET ContainerLineId = NULL
        OUTPUT inserted.Id INTO @Freed (Id)
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN logistics.ContainerLines cl ON cl.Id = l.ContainerLineId
        WHERE l.DocumentId = @InvoiceId AND cl.ContainerId = @ContainerId;
        SET @Pieces = (SELECT SUM(l.QuantityBase) FROM purchase.PurchaseDocumentLines l INNER JOIN @Freed f ON f.Id = l.Id);

        -- back into the unlinked line of the same kind: the one that was there before, else the first freed one
        DECLARE @Merge TABLE (Id INT PRIMARY KEY, KeeperId INT NOT NULL);
        INSERT INTO @Merge (Id, KeeperId)
        SELECT g.Id, g.KeeperId
        FROM (SELECT l.Id,
                     IsFreed  = CASE WHEN f.Id IS NOT NULL THEN 1 ELSE 0 END,
                     KeeperId = FIRST_VALUE(l.Id) OVER (PARTITION BY l.SourceLineId, l.ItemId, l.ItemUnitId, l.UnitPrice, l.DiscountPercent,
                                                                     l.WarehouseId, l.ExpiryDate
                                                        ORDER BY CASE WHEN f.Id IS NULL THEN 0 ELSE 1 END, l.Id)
              FROM purchase.PurchaseDocumentLines l
              LEFT JOIN @Freed f ON f.Id = l.Id
              WHERE l.DocumentId = @InvoiceId AND l.ContainerLineId IS NULL) g
        WHERE g.IsFreed = 1 AND g.Id <> g.KeeperId;

        UPDATE k SET Quantity = k.Quantity + x.Qty
        FROM purchase.PurchaseDocumentLines k
        INNER JOIN (SELECT m.KeeperId, Qty = SUM(l.Quantity) FROM @Merge m
                    INNER JOIN purchase.PurchaseDocumentLines l ON l.Id = m.Id GROUP BY m.KeeperId) x ON x.KeeperId = k.Id;
        DELETE l FROM purchase.PurchaseDocumentLines l INNER JOIN @Merge m ON m.Id = l.Id;

        UPDATE l SET LineNumber = x.Seq
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN (SELECT pl.Id, Seq = ROW_NUMBER() OVER (ORDER BY CASE WHEN pl.ContainerLineId IS NULL THEN 1 ELSE 0 END,
                                                                    c.ContainerRef, cl.LineNumber, pl.LineNumber, pl.Id)
                    FROM purchase.PurchaseDocumentLines pl
                    LEFT JOIN logistics.ContainerLines cl ON cl.Id = pl.ContainerLineId
                    LEFT JOIN logistics.Containers c      ON c.Id = cl.ContainerId
                    WHERE pl.DocumentId = @InvoiceId) x ON x.Id = l.Id
        WHERE l.LineNumber <> x.Seq;

        -- the document total does not change: a rounding difference goes on the line the pieces went back to
        DECLARE @LastLine INT = (SELECT TOP (1) KeeperId FROM @Merge ORDER BY KeeperId DESC);
        DECLARE @Diff DECIMAL(18,2) = @OldTotal - (SELECT ISNULL(SUM(LineTotal), 0) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId);
        IF @Diff <> 0 AND @LastLine IS NOT NULL
            UPDATE purchase.PurchaseDocumentLines
            SET UnitPrice = ROUND(UnitPrice + @Diff / NULLIF(Quantity * (1 - DiscountPercent / 100.0), 0), 4)
            WHERE Id = @LastLine;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / d.ExchangeRate, 2), TotalLandedCostBase = ROUND(x.Amt / d.ExchangeRate, 2) + d.TotalChargesBase,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId) x
        WHERE d.Id = @InvoiceId;

        EXEC logistics.usp_Container_ReallocateCharges @ContainerId, 1, 1;
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@ContainerId, N'Updated', N'Unlinked from purchase invoice ' + @Number + N': ' + CAST(ISNULL(@Pieces, 0) AS NVARCHAR(20)) + N' pieces', @UserId);
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@InvoiceId, N'Updated', N'Unlinked from container ' + @Ref + N' (' + CAST(ISNULL(@Pieces, 0) AS NVARCHAR(20)) + N')', @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC purchase.usp_PurchaseInvoice_ContainerSummary @InvoiceId;
END
GO

/* ================================================================== 14. Check */

SELECT o.ObjectName, ObjectType = ISNULL(so.type_desc, N'MISSING')
FROM (VALUES (N'purchase.fn_PurchaseInvoice_TakesContainers'), (N'purchase.fn_PurchaseInvoice_Unlinked'),
             (N'purchase.fn_PurchaseInvoice_ItemContainers'),
             (N'purchase.usp_PurchaseDocument_Save'), (N'purchase.usp_PurchaseDocument_Post'),
             (N'purchase.usp_PurchaseDocument_CreateFromSource'), (N'purchase.usp_PurchaseDocument_Get'),
             (N'logistics.usp_Container_AvailablePoLines'), (N'logistics.usp_Container_Save'),
             (N'logistics.usp_Container_PlanFromOrder'), (N'logistics.usp_Container_CreateBatch'),
             (N'purchase.usp_PurchaseInvoice_ContainerSummary'), (N'purchase.usp_PurchaseInvoice_LinkCandidates'),
             (N'purchase.usp_PurchaseInvoice_LinkContainers'), (N'purchase.usp_PurchaseInvoice_UnlinkContainer')) o (ObjectName)
LEFT JOIN sys.objects so ON so.object_id = OBJECT_ID(o.ObjectName)
ORDER BY ObjectType, o.ObjectName;                                    -- expected 15: 3 functions, 12 procedures, none MISSING

-- Invoices shipped in containers with pieces not in a container yet: link them from the Containers card of the invoice
-- (a posted one receives those pieces only at the offload of the containers they are linked to).
SELECT d.Id, d.DocumentNumber, Status = CASE d.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Posted' END,
       i.ItemCode, UnlinkedPieces = SUM(l.QuantityBase)
FROM purchase.PurchaseDocuments d
INNER JOIN inventory.DocumentTypes dt       ON dt.Id = d.DocumentTypeId
INNER JOIN purchase.PurchaseDocumentLines l ON l.DocumentId = d.Id
INNER JOIN inventory.Items i                ON i.Id = l.ItemId
WHERE dt.Code = N'PINV' AND d.Status IN (1, 2) AND d.ReceiptMode = 2 AND l.ContainerLineId IS NULL
GROUP BY d.Id, d.DocumentNumber, d.Status, i.ItemCode
ORDER BY d.Id, i.ItemCode;

PRINT 'Script 43 applied: purchase invoices shipped in containers - switch, link, unlink, summary, containers from the invoice.';
GO

SET NOEXEC OFF;
GO
