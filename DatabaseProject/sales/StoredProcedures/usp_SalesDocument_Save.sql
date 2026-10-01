CREATE   PROCEDURE sales.usp_SalesDocument_Save
    @Id                 INT            = NULL,
    @DocumentTypeCode   NVARCHAR(20)   = N'SINV',
    @DocumentDate       DATE,
    @DueDate            DATE           = NULL,
    @BranchId           INT,
    @WarehouseId        INT = NULL,
    @ClientId           INT,
    @SalesmanId         INT            = NULL,
    @PriceListId        INT,
    /* The currency the customer is billed in. NULL = the price list's, which is how it has always
       worked; a different one converts every list price with the two rates. */
    @CurrencyId         INT            = NULL,
    @RateType           TINYINT        = 1,
    @ExchangeRate       DECIMAL(18,6)  = NULL,
    @ReferenceNo        NVARCHAR(100)  = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @Lines              sales.tvp_SalesDocumentLine READONLY,
    @AllowPriceOverride BIT            = 0,
    @MaxDiscountPercent DECIMAL(9,4)   = 100,
    @DraftReference     NVARCHAR(50)   = NULL,
    /* HOW THE CUSTOMER PAYS: 1 Cash (a receipt is created and posted with the invoice), 2 On Account
       (paid later by receipts). The method, account and reference only mean something for Cash. */
    @PaymentType        TINYINT        = NULL,
    @ReceiptMethodId    INT            = NULL,
    @ReceiptAccountId   INT            = NULL,
    @PaymentReference   NVARCHAR(100)  = NULL,
    @RowVersion         BINARY(8)      = NULL,
    @UserId             INT            = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* The warehouse lives on the LINES. The header keeps one so that document lists, filters,
       reports and exports still have a warehouse to show; when the caller does not send one it is
       taken from the first line. */
    IF @WarehouseId IS NULL
        SELECT TOP (1) @WarehouseId = WarehouseId FROM @Lines ORDER BY LineNumber;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @DraftReference = NULLIF(LTRIM(RTRIM(@DraftReference)), N'');

    DECLARE @TypeId INT, @Direction SMALLINT, @ResolvedCurrencyId INT, @Rate DECIMAL(18,6), @PriceRate DECIMAL(18,6);
    /* NAMED ARGUMENTS: the validator has grown two parameters and a positional call would quietly
       hand them the wrong values. */
    EXEC sales.usp_SalesDocument_ValidateInput
         @DocumentTypeCode = @DocumentTypeCode, @DocumentDate = @DocumentDate, @DueDate = @DueDate,
         @BranchId = @BranchId, @WarehouseId = @WarehouseId, @ClientId = @ClientId, @SalesmanId = @SalesmanId,
         @PriceListId = @PriceListId, @RateType = @RateType, @ExchangeRate = @ExchangeRate,
         @MaxDiscountPercent = @MaxDiscountPercent, @Lines = @Lines,
         @InvoiceCurrencyId = @CurrencyId,
         @DocumentTypeId = @TypeId OUTPUT, @StockDirection = @Direction OUTPUT,
         @CurrencyId = @ResolvedCurrencyId OUTPUT, @ResolvedRate = @Rate OUTPUT, @PriceRate = @PriceRate OUTPUT;

    -- From here on the invoice's currency is the resolved one.
    SET @CurrencyId = @ResolvedCurrencyId;

    /* PAYMENT TYPE. Only a sales invoice has one - a return is not paid for. Saving a draft only keeps
       what was chosen (and refuses nonsense); whether the choice is COMPLETE is judged on posting, so
       a draft can be saved half-filled like everything else here. Nothing is created by a save. */
    IF @DocumentTypeCode <> N'SINV' SET @PaymentType = NULL;
    IF @PaymentType IS NOT NULL AND @PaymentType NOT IN (1, 2) THROW 64000, 'Payment Type must be Cash or On Account.', 1;
    SET @PaymentReference = NULLIF(LTRIM(RTRIM(@PaymentReference)), N'');
    IF ISNULL(@PaymentType, 0) <> 1
        SELECT @ReceiptMethodId = NULL, @ReceiptAccountId = NULL, @PaymentReference = NULL;
    ELSE
    BEGIN
        IF @ReceiptMethodId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @ReceiptMethodId AND IsActive = 1)
            THROW 64000, 'The receipt method was not found or is inactive.', 1;
        IF @ReceiptAccountId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.CashBankAccounts WHERE Id = @ReceiptAccountId AND IsActive = 1)
            THROW 64000, 'The cash / bank account was not found or is inactive.', 1;
    END

    -- Source links of a return draft (SINV -> SRET) survive a re-save: kept by line number + item.
    DECLARE @Kept TABLE (LineNumber INT PRIMARY KEY, ItemId INT, SourceLineId INT, UnitCostBase DECIMAL(18,6));

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM sales.SalesDocuments WHERE Id = @Id);
        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 1 THROW 64005, 'Only draft documents can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND DocumentTypeId <> @TypeId)
            THROW 64000, 'The document type cannot be changed.', 1;
        INSERT INTO @Kept (LineNumber, ItemId, SourceLineId, UnitCostBase)
        SELECT LineNumber, ItemId, SourceLineId, UnitCostBase FROM sales.SalesDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL;
    END

    DECLARE @Priced TABLE
    (
        LineNumber INT PRIMARY KEY, ItemId INT, ItemUnitId INT, WarehouseId INT, Specification NVARCHAR(100) NULL, ExpiryDate DATE, Quantity INT, PackingFormula INT,
        UnitPrice DECIMAL(18,4) NULL, SystemPrice DECIMAL(18,4) NULL, DiscountPercent DECIMAL(9,4), ImportRowNumber INT, Notes NVARCHAR(300)
    );
    INSERT INTO @Priced (LineNumber, ItemId, ItemUnitId, WarehouseId, Specification, ExpiryDate, Quantity, PackingFormula, UnitPrice, SystemPrice, DiscountPercent, ImportRowNumber, Notes)
    SELECT l.LineNumber, l.ItemId, l.ItemUnitId, l.WarehouseId, NULLIF(LTRIM(RTRIM(l.Specification)), N''), l.ExpiryDate, l.Quantity, iu.PackingFormula,
           CASE WHEN @AllowPriceOverride = 1 AND l.UnitPrice IS NOT NULL THEN l.UnitPrice ELSE sp.Price END,
           sp.Price, ISNULL(l.DiscountPercent, 0), l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
    FROM @Lines l
    INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
    /* THE LIST PRICE, CONVERTED INTO THE INVOICE CURRENCY. fn_GetUnitPrice answers in the price
       list's currency; dividing by its rate gives the base currency and multiplying by the
       invoice's gives what the customer is billed. Both rates are 1 on a base-currency invoice
       priced from a base-currency list, so the ordinary case multiplies by 1. */
    CROSS APPLY (SELECT ROUND(masterdata.fn_GetUnitPrice(l.ItemUnitId, @PriceListId, @BranchId) * @Rate / @PriceRate, 4) AS Price) sp;

    -- Return lines created from an invoice keep the invoice price and discount (the customer is refunded what was paid).
    UPDATE p SET UnitPrice = s.UnitPrice, DiscountPercent = s.DiscountPercent, SystemPrice = s.UnitPrice
    FROM @Priced p
    INNER JOIN @Kept k ON k.LineNumber = p.LineNumber AND k.ItemId = p.ItemId
    INNER JOIN sales.SalesDocumentLines s ON s.Id = k.SourceLineId;

    DECLARE @NoPrice NVARCHAR(400);
    SELECT TOP (1) @NoPrice = N'Line ' + CAST(p.LineNumber AS NVARCHAR(10)) + N': no selling price for ' + i.ItemCode + N' (' + ut.UnitTypeName
                              + N') in price list ' + pl.PriceListName + N'. Add the price or enter a manual price (requires the price override permission).'
    FROM @Priced p
    INNER JOIN inventory.Items i       ON i.Id = p.ItemId
    INNER JOIN inventory.ItemUnits iu  ON iu.Id = p.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.PriceLists pl ON pl.Id = @PriceListId
    WHERE p.UnitPrice IS NULL
    ORDER BY p.LineNumber;
    IF @NoPrice IS NOT NULL THROW 64011, @NoPrice, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO sales.SalesDocuments (DocumentTypeId, DocumentNumber, DocumentDate, DueDate, BranchId, WarehouseId, ClientId, SalesmanId,
                                              PriceListId, CurrencyId, RateType, ExchangeRate, ReferenceNo, Notes, Status, CreatedBy,
                                              PaymentType, ReceiptMethodId, ReceiptAccountId, PaymentReference)
            VALUES (@TypeId, @Number, @DocumentDate, @DueDate, @BranchId, @WarehouseId, @ClientId, @SalesmanId,
                    @PriceListId, @CurrencyId, @RateType, @Rate, @ReferenceNo, @Notes, 1, @UserId,
                    @PaymentType, @ReceiptMethodId, @ReceiptAccountId, @PaymentReference);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Created', ISNULL(N'Draft ' + @Number, N'Draft (number assigned on posting)'), @UserId);
        END
        ELSE
        BEGIN
            UPDATE sales.SalesDocuments
            SET DocumentDate = @DocumentDate, DueDate = @DueDate, BranchId = @BranchId, WarehouseId = @WarehouseId,
                ClientId = @ClientId, SalesmanId = @SalesmanId, PriceListId = @PriceListId, CurrencyId = @CurrencyId,
                RateType = @RateType, ExchangeRate = @Rate, ReferenceNo = @ReferenceNo, Notes = @Notes,
                PaymentType = @PaymentType, ReceiptMethodId = @ReceiptMethodId, ReceiptAccountId = @ReceiptAccountId, PaymentReference = @PaymentReference,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM sales.SalesDocumentLines WHERE DocumentId = @Id;

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        INSERT INTO sales.SalesDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula, Specification,
                                              UnitPrice, DiscountPercent, PriceSource, UnitCostBase, ImportRowNumber, Notes, SourceLineId)
        SELECT @Id, p.LineNumber, p.ItemId, p.ItemUnitId, p.WarehouseId, p.ExpiryDate, p.Quantity, p.PackingFormula, p.Specification,
               p.UnitPrice, p.DiscountPercent,
               CASE WHEN p.SystemPrice IS NULL OR p.UnitPrice <> p.SystemPrice THEN N'Manual' ELSE N'PriceList' END,
               k.UnitCostBase, p.ImportRowNumber, p.Notes, k.SourceLineId
        FROM @Priced p
        LEFT JOIN @Kept k ON k.LineNumber = p.LineNumber AND k.ItemId = p.ItemId;

        UPDATE d
        SET TotalItems = x.Items, TotalQuantity = x.Qty, Subtotal = x.Sub, TotalAmount = x.Amt, TotalDiscount = x.Sub - x.Amt,
            TotalAmountBase = ROUND(x.Amt / @Rate, 2)
        FROM sales.SalesDocuments d
        CROSS APPLY (SELECT COUNT(*) AS Items, ISNULL(SUM(QuantityBase), 0) AS Qty,
                            ISNULL(SUM(CONVERT(DECIMAL(18,2), Quantity * UnitPrice)), 0) AS Sub, ISNULL(SUM(LineTotal), 0) AS Amt
                     FROM sales.SalesDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        IF @DraftReference IS NOT NULL
        BEGIN
            DECLARE @NewLogs TABLE (Id INT PRIMARY KEY, FileName NVARCHAR(255), ImportedRows INT);
            INSERT INTO @NewLogs (Id, FileName, ImportedRows)
            SELECT Id, FileName, ImportedRows FROM sales.InvoiceImportLogs WHERE DraftReference = @DraftReference AND InvoiceId IS NULL;

            EXEC sales.usp_InvoiceImport_AttachInvoice @DraftReference, @Id;

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            SELECT @Id, N'Imported', N'Excel import: ' + FileName + N' (' + CAST(ImportedRows AS NVARCHAR(10)) + N' row(s))', @UserId
            FROM @NewLogs ORDER BY Id;
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

