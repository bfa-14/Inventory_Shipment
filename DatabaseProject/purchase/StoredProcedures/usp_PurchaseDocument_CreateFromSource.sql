/* ================================================================== 5. CreateFromSource: one invoice per item (PO -> PINV) */

-- Re-created (45) from the body of script 43: PO -> PINV one draft per item (receipt mode of 43 kept), other pairs unchanged.
CREATE   PROCEDURE purchase.usp_PurchaseDocument_CreateFromSource
    @SourceId       INT,
    @TargetTypeCode NVARCHAR(20),        -- PINV (from PO) | PRET (from PINV)
    @DocumentDate   DATE = NULL,         -- default today
    @Selection      purchase.tvp_SourceLineSelection READONLY,   -- lines + base quantities to take; empty = everything still available
    @UserId         INT  = NULL,
    @NewId          INT OUTPUT,                       -- (45) PO -> PINV: the FIRST invoice created
    @ExporterReference   NVARCHAR(50) = NULL,         -- (45) PO -> PINV: copied to every invoice created
    @CommercialInvoiceNo NVARCHAR(50) = NULL          -- (45) PO -> PINV: copied to every invoice created
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
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

    -- A return (any pair but PO -> PINV): one document, as before.
    IF @TargetTypeCode <> N'PINV'
    BEGIN
        EXEC purchase.usp_PurchaseDocument_Save
             @Id = NULL, @DocumentTypeCode = @TargetTypeCode, @DocumentDate = @DocumentDate, @ExpectedDate = NULL,
             @BranchId = @BranchId, @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @CurrencyId = @CurrencyId,
             @RateType = @RateType, @ExchangeRate = NULL, @SupplierReference = @SupplierRef, @Notes = NULL,
             @Lines = @Lines, @MaxDiscountPercent = 100, @SourceDocumentId = @SourceId, @RowVersion = NULL, @UserId = @UserId,
             @ReceiptMode = @ReceiptMode, @NewId = @NewId OUTPUT;
        RETURN;
    END

    -- (45) ONE INVOICE PER ITEM: the lines are split by item, in the order of each item's first line, and every invoice
    --      is created exactly as one was before (usp_PurchaseDocument_Save: header, lines, totals, audit), all or nothing.
    DECLARE @Items TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ItemId INT NOT NULL UNIQUE);
    INSERT INTO @Items (ItemId) SELECT ItemId FROM @Lines GROUP BY ItemId ORDER BY MIN(LineNumber);

    DECLARE @Created TABLE (Seq INT PRIMARY KEY, InvoiceId INT NOT NULL);
    DECLARE @Part purchase.tvp_PurchaseDocumentLine;
    DECLARE @Seq INT = 1, @Last INT = (SELECT MAX(Seq) FROM @Items), @Item INT, @InvoiceId INT;

    BEGIN TRY
        BEGIN TRANSACTION;
        WHILE @Seq <= @Last
        BEGIN
            SET @Item = (SELECT ItemId FROM @Items WHERE Seq = @Seq);

            DELETE FROM @Part;
            INSERT INTO @Part (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
            SELECT ROW_NUMBER() OVER (ORDER BY LineNumber), ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent,
                   ImportRowNumber, Notes, SourceLineId
            FROM @Lines WHERE ItemId = @Item;

            SET @InvoiceId = NULL;
            EXEC purchase.usp_PurchaseDocument_Save
                 @Id = NULL, @DocumentTypeCode = N'PINV', @DocumentDate = @DocumentDate, @ExpectedDate = NULL,
                 @BranchId = @BranchId, @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @CurrencyId = @CurrencyId,
                 @RateType = @RateType, @ExchangeRate = NULL, @SupplierReference = @SupplierRef, @Notes = NULL,
                 @Lines = @Part, @MaxDiscountPercent = 100, @SourceDocumentId = @SourceId, @RowVersion = NULL, @UserId = @UserId,
                 @ReceiptMode = @ReceiptMode, @ExporterReference = @ExporterReference, @CommercialInvoiceNo = @CommercialInvoiceNo,
                 @NewId = @InvoiceId OUTPUT;
            INSERT INTO @Created (Seq, InvoiceId) VALUES (@Seq, @InvoiceId);

            SET @Seq += 1;
        END
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    -- the first invoice, as before: the callers that read @NewId keep working
    SET @NewId = (SELECT InvoiceId FROM @Created WHERE Seq = 1);

    SELECT r.Id, r.ItemId, r.ItemCode, r.ItemName, r.LineCount, r.QuantityBase, r.TotalAmount, r.RowVersion
    FROM @Created c CROSS APPLY purchase.fn_PurchaseInvoice_Row(c.InvoiceId) r
    ORDER BY c.Seq;
END

GO

