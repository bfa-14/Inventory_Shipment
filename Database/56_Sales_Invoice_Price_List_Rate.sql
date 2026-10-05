SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   56: Sales invoice - price list rate
   --------------------------------------------------------------------------------------------------
   An invoice billed in another currency than its price list's converts every list price with TWO
   rates: list price x invoice rate / price list rate (both "units per 1 base currency"). The second
   one was always the published rate and was never shown; a USD invoice from a CDF list therefore
   showed an exchange rate of 1 and nothing the reader could change.

     sales.SalesDocuments.PriceListRate     the price list's rate the invoice used, when the two
                                            currencies differ (NULL otherwise and on older invoices)
     usp_SalesDocument_ValidateInput / _Save   take @PriceListRate (NULL = the published one)
     usp_SalesDocument_Get                     returns it
     usp_SalesDocument_ResolveRate             answers for the price list's currency too, and works
                                               without a price list (the currency is chosen first)

   ALSO FIXED: an invoice in its price list's own currency (not the base) with a typed exchange rate
   scaled every line by typed / published rate. One currency now means no conversion.
   ================================================================================================== */

IF OBJECT_ID(N'sales.usp_SalesDocument_Save', N'P') IS NULL
BEGIN
    RAISERROR ('The sales document scripts must run before script 56.', 16, 1);
    SET NOEXEC ON;
END
GO

IF COL_LENGTH(N'sales.SalesDocuments', N'PriceListRate') IS NULL
    ALTER TABLE sales.SalesDocuments ADD PriceListRate DECIMAL(18,6) NULL;
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_ValidateInput
    @DocumentTypeCode   NVARCHAR(20),
    @DocumentDate       DATE,
    @DueDate            DATE,
    @BranchId           INT,
    @WarehouseId        INT = NULL,
    @ClientId           INT,
    @SalesmanId         INT,
    @PriceListId        INT,
    @RateType           TINYINT,
    @ExchangeRate       DECIMAL(18,6),
    @MaxDiscountPercent DECIMAL(9,4),
    @Lines              sales.tvp_SalesDocumentLine READONLY,
    @DocumentTypeId     INT OUTPUT,
    @StockDirection     SMALLINT OUTPUT,
    @CurrencyId         INT OUTPUT,
    @ResolvedRate       DECIMAL(18,6) OUTPUT,
    /* THE INVOICE CURRENCY, when the header chose one that is not the price list's. NULL keeps the
       old behaviour: the invoice is issued in the currency its price list prices in. */
    @InvoiceCurrencyId  INT = NULL,
    /* The rate of the PRICE LIST's currency, so the caller can convert a list price into the
       invoice currency. Equal to @ResolvedRate whenever the two currencies are the same. */
    @PriceRate          DECIMAL(18,6) OUTPUT,
    /* (56) The rate typed for the PRICE LIST's currency, when it is not the invoice's; NULL = the
       published one. It is what converts a list price into the invoice currency. */
    @PriceListRate      DECIMAL(18,6) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Sales' AND IsActive = 1;
    IF @DocumentTypeId IS NULL THROW 64008, 'Document type not found, inactive, or not a sales document.', 1;

    IF @DocumentDate IS NULL THROW 64000, 'Document Date is required.', 1;
    /* ONE DAY OF TOLERANCE, because this compares a LOCAL date against a UTC one. The date on the
       document is the one the reader sees on their own clock; SYSUTCDATETIME() is the server's in
       UTC. East of Greenwich the two disagree for the first hours after midnight - at 00:20 in
       Beirut (UTC+3) it is still yesterday in UTC, so a document dated today was refused as being
       in the future. A day covers every offset without letting a genuinely future date through by
       more than one. */
    IF @DocumentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 64000, 'Document Date cannot be in the future.', 1;
    IF @DueDate IS NOT NULL AND @DueDate < @DocumentDate THROW 64000, 'Due Date cannot be before the Document Date.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 64008, 'Branch not found or inactive.', 1;
    IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1)
        THROW 64008, 'The header warehouse must be an active warehouse.', 1;
    IF @ClientId IS NULL THROW 64000, 'Client is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @ClientId AND IsClient = 1 AND IsActive = 1)
        THROW 64008, 'Client not found, inactive, or not flagged as a client.', 1;
    IF @SalesmanId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SalesmanId AND IsSalesman = 1 AND IsActive = 1)
        THROW 64008, 'Salesman not found, inactive, or not flagged as a salesman.', 1;
    IF @PriceListId IS NULL THROW 64000, 'Price List is required.', 1;

    /* THE PRICE LIST'S CURRENCY prices the lines; the INVOICE's currency is what the customer is
       billed in. They were always the same, and by default still are. When the header chooses a
       different one, both rates are resolved: the caller converts a list price into the invoice
       currency with @ResolvedRate / @PriceRate. */
    DECLARE @PriceCurrencyId INT;
    SELECT @PriceCurrencyId = CurrencyId FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1;
    IF @PriceCurrencyId IS NULL THROW 64008, 'Price list not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @PriceCurrencyId AND IsActive = 1)
        THROW 64008, 'The price list currency is inactive.', 1;

    SET @CurrencyId = ISNULL(@InvoiceCurrencyId, @PriceCurrencyId);
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsActive = 1)
        THROW 64008, 'The invoice currency was not found or is inactive.', 1;

    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) THROW 64000, 'Rate type must be Official, Non-official or Market.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 64000, 'Exchange rate must be greater than zero.', 1;
    IF @PriceListRate IS NOT NULL AND @PriceListRate <= 0 THROW 64000, 'The price list rate must be greater than zero.', 1;

    /* The price list's rate is never the typed one: @ExchangeRate is the rate the header states for
       the INVOICE currency, and using it to undo the list currency would price the lines twice. */
    SET @PriceRate = CASE WHEN @PriceListRate IS NOT NULL AND @PriceCurrencyId <> @CurrencyId THEN @PriceListRate
                          ELSE masterdata.fn_GetRate(@PriceCurrencyId, @RateType, @DocumentDate) END;
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @PriceCurrencyId AND IsBaseCurrency = 1) SET @PriceRate = 1;

    SET @ResolvedRate = COALESCE(@ExchangeRate, masterdata.fn_GetRate(@CurrencyId, @RateType, @DocumentDate));
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @CurrencyId AND IsBaseCurrency = 1) SET @ResolvedRate = 1;
    /* (56) ONE CURRENCY, NO CONVERSION. Billed in the list's own currency, a list price is the price:
       dividing by the published rate and multiplying by a typed one scaled every line by the gap. */
    IF @PriceCurrencyId = @CurrencyId SET @PriceRate = @ResolvedRate;

    IF @PriceRate IS NULL
    BEGIN
        DECLARE @PriceCur NVARCHAR(3) = (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @PriceCurrencyId);
        DECLARE @PriceMsg NVARCHAR(300) = N'No ' + CASE @RateType WHEN 1 THEN N'official' WHEN 2 THEN N'non-official' ELSE N'market' END
                                        + N' exchange rate is defined for the price list currency ' + @PriceCur
                                        + N' on or before ' + CONVERT(NVARCHAR(10), @DocumentDate, 120)
                                        + N'. Add one in Master Data > Exchange Rates.';
        THROW 64008, @PriceMsg, 1;
    END
    IF @ResolvedRate IS NULL
    BEGIN
        DECLARE @Cur NVARCHAR(3) = (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @CurrencyId);
        DECLARE @RateMsg NVARCHAR(300) = N'No ' + CASE @RateType WHEN 1 THEN N'official' WHEN 2 THEN N'non-official' ELSE N'market' END
                                       + N' exchange rate is defined for ' + @Cur + N' on or before ' + CONVERT(NVARCHAR(10), @DocumentDate, 120)
                                       + N'. Add one in Master Data > Exchange Rates or enter the rate manually.';
        THROW 64008, @RateMsg, 1;
    END

    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;
    IF @MaxDiscountPercent > 100 SET @MaxDiscountPercent = 100;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN i.Id IS NULL THEN N'item not found.'
             WHEN i.IsActive = 0 THEN N'item ' + i.ItemCode + N' is inactive.'
             WHEN iu.Id IS NULL THEN N'the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN w.Id IS NULL OR w.IsActive = 0 THEN N'warehouse not found or inactive.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'quantity must be greater than zero.'
             WHEN l.UnitPrice IS NOT NULL AND l.UnitPrice < 0 THEN N'unit price cannot be negative.'
             WHEN l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent)
                  THEN N'discount must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(12)) + N'%.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i      ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    LEFT JOIN masterdata.Warehouses w  ON w.Id = l.WarehouseId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL OR w.Id IS NULL OR w.IsActive = 0
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitPrice IS NOT NULL AND l.UnitPrice < 0)
       OR (l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent))
    ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 64000, @Msg, 1;
END

GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Save
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
    @NewId              INT OUTPUT,
    /* (56) The rate of the price list's currency when the invoice is billed in another; NULL = the
       published one. Kept on the invoice, so a reopened draft converts its lines the same way. */
    @PriceListRate      DECIMAL(18,6)  = NULL
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
         @CurrencyId = @ResolvedCurrencyId OUTPUT, @ResolvedRate = @Rate OUTPUT, @PriceRate = @PriceRate OUTPUT, @PriceListRate = @PriceListRate;

    -- From here on the invoice's currency is the resolved one.
    SET @CurrencyId = @ResolvedCurrencyId;
    -- (56) the price list's rate is only worth keeping when the two currencies differ
    DECLARE @StoredPriceRate DECIMAL(18,6) =
        CASE WHEN (SELECT CurrencyId FROM masterdata.PriceLists WHERE Id = @PriceListId) <> @CurrencyId THEN @PriceRate END;

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
                                              PriceListId, CurrencyId, RateType, ExchangeRate, PriceListRate, ReferenceNo, Notes, Status, CreatedBy,
                                              PaymentType, ReceiptMethodId, ReceiptAccountId, PaymentReference)
            VALUES (@TypeId, @Number, @DocumentDate, @DueDate, @BranchId, @WarehouseId, @ClientId, @SalesmanId,
                    @PriceListId, @CurrencyId, @RateType, @Rate, @StoredPriceRate, @ReferenceNo, @Notes, 1, @UserId,
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
                RateType = @RateType, ExchangeRate = @Rate, PriceListRate = @StoredPriceRate, ReferenceNo = @ReferenceNo, Notes = @Notes,
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

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.DueDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.ClientId, cl.PartyCode AS ClientCode, cl.PartyName AS ClientName, cl.Phone AS ClientPhone, cl.Email AS ClientEmail, cl.Address AS ClientAddress,
           d.SalesmanId, sm.PartyCode AS SalesmanCode, sm.PartyName AS SalesmanName,
           d.PriceListId, pl.PriceListCode, pl.PriceListName,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, d.PriceListRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.ReferenceNo, d.Notes, d.Status,
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase, d.TotalCostBase, d.TotalGrossProfitBase,
           st.PaidAmount, st.OutstandingAmount, st.PaymentStatus,
           d.PaymentType, d.ReceiptMethodId, ReceiptMethodName = rm.MethodName,
           d.ReceiptAccountId, ReceiptAccountCode = ra.AccountCode, ReceiptAccountName = ra.AccountName, d.PaymentReference,
           ReceiptId = rc.Id, rc.ReceiptNumber,
           ReceiptStatus = CASE rc.Status WHEN 1 THEN N'Draft' WHEN 2 THEN N'Posted' WHEN 3 THEN N'Reversed' END,
           TotalGrossProfitPct = CASE WHEN d.TotalAmountBase > 0 THEN ROUND(100.0 * d.TotalGrossProfitBase / d.TotalAmountBase, 2) END,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion
    FROM sales.SalesDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties cl      ON cl.Id = d.ClientId
    LEFT  JOIN masterdata.Parties sm      ON sm.Id = d.SalesmanId
    INNER JOIN masterdata.PriceLists pl   ON pl.Id = d.PriceListId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN sales.SalesDocuments src   ON src.Id = d.SourceDocumentId
    OUTER APPLY sales.fn_InvoiceSettlement(d.Id) st
    LEFT  JOIN masterdata.PaymentMethods rm   ON rm.Id = d.ReceiptMethodId
    LEFT  JOIN masterdata.CashBankAccounts ra ON ra.Id = d.ReceiptAccountId
    LEFT  JOIN sales.Receipts rc              ON rc.SourceSalesDocumentId = d.Id
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.Specification, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal, l.PriceSource,
           l.UnitCostBase, l.FobCostAtSale, l.LastCostAtSale, l.NetSalesBase, l.CogsBase, l.GrossProfitBase, l.GrossProfitPct,
           l.ReturnedQuantityBase, RemainingBase = l.QuantityBase - l.ReturnedQuantityBase,
           l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           SystemPrice = masterdata.fn_GetUnitPrice(l.ItemUnitId, d.PriceListId, d.BranchId),
           ItemAverageCost = i.AverageCost
    FROM sales.SalesDocumentLines l
    INNER JOIN sales.SalesDocuments d   ON d.Id = l.DocumentId
    INNER JOIN inventory.Items i        ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu   ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut  ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w  ON w.Id = l.WarehouseId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM sales.SalesDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM sales.SalesDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_ResolveRate
    /* (56) Optional: the invoice currency is chosen first now, and its rate is known before any list. */
    @PriceListId INT     = NULL,
    @RateType    TINYINT = 1,
    @AsOfDate    DATE    = NULL,
    /* The currency the invoice is billed in. NULL answers for the price list's currency. */
    @CurrencyId  INT     = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @AsOfDate IS NULL SET @AsOfDate = CAST(SYSUTCDATETIME() AS DATE);
    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) SET @RateType = 1;

    DECLARE @ListCurrencyId INT = (SELECT CurrencyId FROM masterdata.PriceLists WHERE Id = @PriceListId);
    -- a price list that does not exist answers nothing, as before
    IF @PriceListId IS NOT NULL AND @ListCurrencyId IS NULL RETURN;
    DECLARE @Answer INT = COALESCE(@CurrencyId, @ListCurrencyId);

    /* BOTH CURRENCIES. The invoice's rate values the invoice in the base currency; the price list's
       converts its prices into the invoice currency (list price x invoice rate / list rate). */
    SELECT PriceListId = @PriceListId, c.Id AS CurrencyId, c.CurrencyCode, c.Symbol, c.DecimalPlaces, c.IsBaseCurrency,
           RateType = @RateType,
           Rate     = masterdata.fn_GetRate(c.Id, @RateType, @AsOfDate),
           RateDate = CASE WHEN c.IsBaseCurrency = 1 THEN @AsOfDate
                           ELSE (SELECT TOP (1) RateDate FROM masterdata.ExchangeRates
                                 WHERE CurrencyId = c.Id AND RateType = @RateType AND RateDate <= @AsOfDate ORDER BY RateDate DESC) END,
           BaseCurrencyCode = (SELECT TOP (1) CurrencyCode FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1),
           PriceListCurrencyId     = pc.Id,
           PriceListCurrencyCode   = pc.CurrencyCode,
           PriceListIsBaseCurrency = pc.IsBaseCurrency,
           PriceListRate           = CASE WHEN pc.IsBaseCurrency = 1 THEN 1 ELSE masterdata.fn_GetRate(pc.Id, @RateType, @AsOfDate) END,
           PriceListRateDate       = CASE WHEN pc.IsBaseCurrency = 1 THEN @AsOfDate
                                          ELSE (SELECT TOP (1) RateDate FROM masterdata.ExchangeRates
                                                WHERE CurrencyId = pc.Id AND RateType = @RateType AND RateDate <= @AsOfDate ORDER BY RateDate DESC) END
    FROM masterdata.Currencies c
    LEFT JOIN masterdata.Currencies pc ON pc.Id = @ListCurrencyId
    WHERE c.Id = @Answer;
END
GO

PRINT 'Script 56 applied: sales invoice price list rate.';
GO

SET NOEXEC OFF;
GO
