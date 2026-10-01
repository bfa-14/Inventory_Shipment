CREATE   PROCEDURE purchase.usp_PurchaseDocument_Save
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
        IF NOT EXISTS (SELECT 1 FROM @LineContainers)
           AND EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND ContainerLineId IS NOT NULL)
            THROW 65019, 'This invoice comes from containers: every line must keep its container line.', 1;
    END

    -- Invoice from containers (imports): every line points to a container line of the same order line and item, within
    -- what is loaded and not yet invoiced elsewhere. Receipt mode is automatic: 2 with containers, 1 without.
    IF EXISTS (SELECT 1 FROM @LineContainers)
    BEGIN
        IF @DocumentTypeCode <> N'PINV' THROW 65019, 'Only purchase invoices can be linked to containers.', 1;
        IF @SourceDocumentId IS NULL THROW 65019, 'An invoice from containers must refer to its purchase order.', 1;
        IF EXISTS (SELECT 1 FROM @Lines l WHERE NOT EXISTS (SELECT 1 FROM @LineContainers x WHERE x.LineNumber = l.LineNumber))
           OR EXISTS (SELECT 1 FROM @LineContainers x WHERE NOT EXISTS (SELECT 1 FROM @Lines l WHERE l.LineNumber = x.LineNumber))
            THROW 65019, 'Every line of an invoice from containers must come from a container line.', 1;
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

        SET @ReceiptMode = 2;
    END
    ELSE IF @DocumentTypeCode = N'PINV'
        SET @ReceiptMode = 1;

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

