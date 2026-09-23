-- invoice is allocated to a container).
CREATE   PROCEDURE purchase.usp_PurchaseDocument_Save
    @Id                  INT            = NULL,
    @DocumentTypeCode    NVARCHAR(20),
    @DocumentDate        DATE,
    @ExpectedDate        DATE           = NULL,
    @BranchId            INT,
    @WarehouseId         INT,
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
    @NewId               INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

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
        -- An invoice already loaded into a container is always received at offload.
        IF EXISTS (SELECT 1 FROM logistics.ContainerInvoices ci INNER JOIN logistics.Containers c ON c.Id = ci.ContainerId
                   WHERE ci.PurchaseDocumentId = @Id AND c.Status <> 8)
            SET @ReceiptMode = 2;
        -- Lines that are allocated to a container cannot be replaced.
        IF EXISTS (SELECT 1 FROM logistics.ContainerLines cl INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                   WHERE cl.PurchaseDocumentId = @Id AND c.Status <> 8)
            THROW 69012, 'This invoice has quantities loaded into a container. Remove them from the container before changing the lines.', 1;
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

            -- Lines of cancelled containers protect nothing: they are cleaned up first.
            DELETE cl FROM logistics.ContainerLines cl
            INNER JOIN logistics.Containers c2 ON c2.Id = cl.ContainerId
            WHERE cl.PurchaseDocumentId = @Id AND c2.Status = 8;

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
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, @WarehouseId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
               ISNULL(l.UnitPrice, ROUND(ISNULL(i.LastCost, 0) * iu.PackingFormula * @Rate, 4)),
               ISNULL(l.DiscountPercent, 0),
               CASE WHEN @DocumentTypeCode = N'PRET' THEN src.UnitCostBase END,      -- returns carry the invoice LANDED cost
               CASE WHEN @DocumentTypeCode = N'PRET' THEN src.FobCostBase END,
               l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N''), l.SourceLineId
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        LEFT  JOIN purchase.PurchaseDocumentLines src ON src.Id = l.SourceLineId;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / @Rate, 2), TotalLandedCostBase = ROUND(x.Amt / @Rate, 2) + d.TotalChargesBase
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

