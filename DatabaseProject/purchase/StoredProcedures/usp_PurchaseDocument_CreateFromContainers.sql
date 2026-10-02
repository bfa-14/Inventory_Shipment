/* ================================================================== 4. CreateFromContainers: one invoice per item */

-- Re-created (45) from the body of script 27: one draft per item, + @ExporterReference / @CommercialInvoiceNo.
CREATE   PROCEDURE purchase.usp_PurchaseDocument_CreateFromContainers
    @PurchaseOrderId INT,
    @Selection       logistics.tvp_ContainerLineQty READONLY,
    @DocumentDate    DATE = NULL,
    @UserId          INT  = NULL,
    @NewId           INT OUTPUT,                      -- (45) the FIRST invoice created
    @ExporterReference   NVARCHAR(50) = NULL,         -- (45) copied to every invoice created
    @CommercialInvoiceNo NVARCHAR(50) = NULL          -- (45) copied to every invoice created
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @TypeCode NVARCHAR(20), @Status TINYINT, @BranchId INT, @WarehouseId INT, @SupplierId INT, @CurrencyId INT,
            @RateType TINYINT, @SupplierRef NVARCHAR(100);
    SELECT @TypeCode = dt.Code, @Status = d.Status, @BranchId = d.BranchId, @WarehouseId = d.WarehouseId, @SupplierId = d.SupplierId,
           @CurrencyId = d.CurrencyId, @RateType = d.RateType, @SupplierRef = d.SupplierReference
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    WHERE d.Id = @PurchaseOrderId;

    IF @TypeCode IS NULL THROW 65006, 'Purchase order not found.', 1;
    IF @TypeCode <> N'PO' THROW 65011, 'Invoices from containers are created for a purchase order.', 1;
    IF @Status <> 2 THROW 65011, 'The purchase order must be approved and still open.', 1;

    DECLARE @Pick TABLE (ContainerLineId INT PRIMARY KEY, QuantityBase INT);
    IF EXISTS (SELECT 1 FROM @Selection)
        INSERT INTO @Pick (ContainerLineId, QuantityBase) SELECT ContainerLineId, QuantityBase FROM @Selection;
    ELSE
        INSERT INTO @Pick (ContainerLineId, QuantityBase)
        SELECT cl.Id, cl.QuantityBase - ISNULL(q.Qty, 0)
        FROM logistics.ContainerLines cl
        INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
        OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
        WHERE cl.PurchaseOrderId = @PurchaseOrderId AND c.Status NOT IN (6, 7, 8) AND cl.QuantityBase - ISNULL(q.Qty, 0) > 0;

    IF NOT EXISTS (SELECT 1 FROM @Pick) THROW 65019, 'Nothing is left to invoice on the containers of this order.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        CASE WHEN cl.Id IS NULL THEN N'A selected container line no longer exists.'
             WHEN cl.PurchaseOrderId <> @PurchaseOrderId THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' belongs to another purchase order.'
             WHEN c.Status IN (6, 7, 8) THEN N'Container ' + c.ContainerRef + N' is already offloaded, closed or cancelled.'
             WHEN p.QuantityBase <= 0 THEN N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': the quantity must be greater than zero.'
             ELSE N'Container ' + c.ContainerRef + N' line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': ' + CAST(p.QuantityBase AS NVARCHAR(20))
                  + N' selected but only ' + CAST(cl.QuantityBase - ISNULL(q.Qty, 0) AS NVARCHAR(20)) + N' are loaded and not yet invoiced.' END
    FROM @Pick p
    LEFT JOIN logistics.ContainerLines cl ON cl.Id = p.ContainerLineId
    LEFT JOIN logistics.Containers c      ON c.Id = cl.ContainerId
    OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND pd.Status <> 3) q
    WHERE cl.Id IS NULL OR cl.PurchaseOrderId <> @PurchaseOrderId OR c.Status IN (6, 7, 8) OR p.QuantityBase <= 0
       OR p.QuantityBase > cl.QuantityBase - ISNULL(q.Qty, 0)
    ORDER BY c.ContainerRef, cl.LineNumber;
    IF @Msg IS NOT NULL THROW 65019, @Msg, 1;

    -- the order line must still allow it (posted invoices + drafts)
    SELECT TOP (1) @Msg = N'Order line ' + CAST(pol.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): ' + CAST(x.Qty AS NVARCHAR(20))
                          + N' selected but only ' + CAST(pol.QuantityBase - pol.ReceivedQuantityBase - ISNULL(dr.Qty, 0) AS NVARCHAR(20))
                          + N' remain to invoice (the rest is in posted or draft invoices).'
    FROM (SELECT cl.PoLineId, Qty = SUM(p.QuantityBase) FROM @Pick p
          INNER JOIN logistics.ContainerLines cl ON cl.Id = p.ContainerLineId GROUP BY cl.PoLineId) x
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = x.PoLineId
    INNER JOIN inventory.Items i                  ON i.Id = pol.ItemId
    OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments pd ON pd.Id = pil.DocumentId
                 WHERE pil.SourceLineId = pol.Id AND pd.Status = 1) dr
    WHERE x.Qty > pol.QuantityBase - pol.ReceivedQuantityBase - ISNULL(dr.Qty, 0)
    ORDER BY pol.LineNumber;
    IF @Msg IS NOT NULL THROW 65011, @Msg, 1;

    DECLARE @Rows TABLE (LineNumber INT PRIMARY KEY, ContainerLineId INT, PoLineId INT, QuantityBase INT);
    INSERT INTO @Rows (LineNumber, ContainerLineId, PoLineId, QuantityBase)
    SELECT ROW_NUMBER() OVER (ORDER BY c.ContainerRef, cl.LineNumber), cl.Id, cl.PoLineId, p.QuantityBase
    FROM @Pick p
    INNER JOIN logistics.ContainerLines cl ON cl.Id = p.ContainerLineId
    INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId;

    DECLARE @Lines purchase.tvp_PurchaseDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes, SourceLineId)
    SELECT r.LineNumber, pol.ItemId, u.ItemUnitId, @WarehouseId, pol.ExpiryDate, u.Quantity, u.UnitPrice, pol.DiscountPercent, NULL,
           LEFT(N'Container ' + c.ContainerRef + ISNULL(N' / ' + c.ContainerNo, N''), 300), pol.Id
    FROM @Rows r
    INNER JOIN logistics.ContainerLines cl        ON cl.Id = r.ContainerLineId
    INNER JOIN logistics.Containers c             ON c.Id = cl.ContainerId
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = r.PoLineId
    CROSS APPLY (SELECT ItemUnitId = CASE WHEN r.QuantityBase % pol.PackingFormula = 0 THEN pol.ItemUnitId
                                          ELSE (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = pol.ItemId AND IsBaseUnit = 1) END,
                        Quantity   = CASE WHEN r.QuantityBase % pol.PackingFormula = 0 THEN r.QuantityBase / pol.PackingFormula ELSE r.QuantityBase END,
                        UnitPrice  = CASE WHEN r.QuantityBase % pol.PackingFormula = 0 THEN pol.UnitPrice ELSE ROUND(pol.UnitPrice / pol.PackingFormula, 4) END) u;

    -- (45) ONE INVOICE PER ITEM: the lines are split by item, in the order of each item's first line, and every invoice
    --      is created exactly as one was before (usp_PurchaseDocument_Save: header, lines, totals, audit), all or nothing.
    DECLARE @Items TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ItemId INT NOT NULL UNIQUE);
    INSERT INTO @Items (ItemId) SELECT ItemId FROM @Lines GROUP BY ItemId ORDER BY MIN(LineNumber);

    DECLARE @Created TABLE (Seq INT PRIMARY KEY, InvoiceId INT NOT NULL);
    DECLARE @Part purchase.tvp_PurchaseDocumentLine, @PartContainers purchase.tvp_LineContainer;
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

            DELETE FROM @PartContainers;
            INSERT INTO @PartContainers (LineNumber, ContainerLineId)
            SELECT ROW_NUMBER() OVER (ORDER BY r.LineNumber), r.ContainerLineId
            FROM @Rows r INNER JOIN @Lines l ON l.LineNumber = r.LineNumber
            WHERE l.ItemId = @Item;

            SET @InvoiceId = NULL;
            EXEC purchase.usp_PurchaseDocument_Save
                 @Id = NULL, @DocumentTypeCode = N'PINV', @DocumentDate = @DocumentDate, @ExpectedDate = NULL,
                 @BranchId = @BranchId, @WarehouseId = @WarehouseId, @SupplierId = @SupplierId, @CurrencyId = @CurrencyId,
                 @RateType = @RateType, @ExchangeRate = NULL, @SupplierReference = @SupplierRef, @Notes = NULL,
                 @Lines = @Part, @MaxDiscountPercent = 100, @SourceDocumentId = @PurchaseOrderId, @RowVersion = NULL, @UserId = @UserId,
                 @ReceiptMode = 2, @ExporterReference = @ExporterReference, @CommercialInvoiceNo = @CommercialInvoiceNo,
                 @LineContainers = @PartContainers, @NewId = @InvoiceId OUTPUT;
            INSERT INTO @Created (Seq, InvoiceId) VALUES (@Seq, @InvoiceId);

            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            SELECT DISTINCT cl.ContainerId, N'Updated',
                   N'Draft purchase invoice ' + ISNULL((SELECT DocumentNumber FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId),
                                                       N'#' + CAST(@InvoiceId AS NVARCHAR(10)))
                   + N' created from the container', @UserId
            FROM @PartContainers x INNER JOIN logistics.ContainerLines cl ON cl.Id = x.ContainerLineId;

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

