SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   65: Document lines take a warehouse at the bottom of the tree, of any branch
   --------------------------------------------------------------------------------------------------
   Every detail line that moves stock (sales invoices and returns, purchase orders, invoices and
   returns, Inventory In and Out, and the Excel imports of these) names a warehouse:
     - of ANY branch: the header's branch numbers the document, it does not limit its lines
       (already so for sales and purchases; script 64 for Inventory In / Out; here for the import's
       default warehouse);
     - at the BOTTOM of the warehouse tree: a warehouse with warehouses under it is a group, not a
       place that holds stock, so no line may take or put stock there.

     masterdata.fn_Warehouse_IsLeaf                  new: 1 when no warehouse stands under it
     sales.usp_SalesDocument_ValidateInput           (save)  refuses a parent warehouse on a line
     purchase.usp_PurchaseDocument_ValidateInput     (save)  the same
     inventory.usp_StockDocument_ValidateInput       (save)  the same
     sales.usp_SalesDocument_Post                    refuses a draft saved before with one
     purchase.usp_PurchaseDocument_Post              the same
     inventory.usp_StockDocument_Post                the same
     sales.usp_InvoiceImport_Validate                the default warehouse may be of any branch but
                                                     must be a leaf; a row naming a parent is an Error
     logistics.usp_Container_Offload                 the offloading warehouse must be a leaf (it stays
                                                     in the container's branch, a rule of its own)

   Each procedure is re-created from its current body with only these changes.
   ================================================================================================== */

CREATE OR ALTER FUNCTION masterdata.fn_Warehouse_IsLeaf (@WarehouseId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE ParentId = @WarehouseId) THEN 0 ELSE 1 END;
END
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

    -- A parent warehouse holds no stock of its own: a line takes a warehouse at the bottom of the tree (script 65).
    IF @Msg IS NULL
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
        FROM @Lines l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
        ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 64000, @Msg, 1;
END

GO

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_ValidateInput
    @DocumentTypeCode   NVARCHAR(20),
    @DocumentDate       DATE,
    @ExpectedDate       DATE,
    @BranchId           INT,
    @WarehouseId        INT = NULL,
    @SupplierId         INT,
    @CurrencyId         INT,             -- NULL = supplier default currency, else base
    @RateType           TINYINT,
    @ExchangeRate       DECIMAL(18,6),   -- NULL = resolve
    @MaxDiscountPercent DECIMAL(9,4),
    @SourceDocumentId   INT,
    @Lines              purchase.tvp_PurchaseDocumentLine READONLY,
    @DocumentTypeId     INT OUTPUT,
    @StockDirection     SMALLINT OUTPUT,
    @ResolvedCurrencyId INT OUTPUT,
    @ResolvedRate       DECIMAL(18,6) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Purchase' AND IsActive = 1;
    IF @DocumentTypeId IS NULL THROW 65008, 'Document type not found, inactive, or not a purchase document.', 1;

    IF @DocumentDate IS NULL THROW 65000, 'Document Date is required.', 1;
    /* ONE DAY OF TOLERANCE, because this compares a LOCAL date against a UTC one. The date on the
       document is the one the reader sees on their own clock; SYSUTCDATETIME() is the server's in
       UTC. East of Greenwich the two disagree for the first hours after midnight - at 00:20 in
       Beirut (UTC+3) it is still yesterday in UTC, so a document dated today was refused as being
       in the future. A day covers every offset without letting a genuinely future date through by
       more than one. */
    IF @DocumentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 65000, 'Document Date cannot be in the future.', 1;
    IF @ExpectedDate IS NOT NULL AND @ExpectedDate < @DocumentDate THROW 65000, 'Expected / due date cannot be before the Document Date.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 65008, 'Branch not found or inactive.', 1;
    IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1)
        THROW 65008, 'The header warehouse must be an active warehouse.', 1;
    IF @SupplierId IS NULL THROW 65000, 'Supplier is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsSupplier = 1 AND IsActive = 1)
        THROW 65008, 'Supplier not found, inactive, or not flagged as a supplier.', 1;

    SET @ResolvedCurrencyId = COALESCE(@CurrencyId,
                                       (SELECT DefaultCurrencyId FROM masterdata.Parties WHERE Id = @SupplierId),
                                       (SELECT TOP (1) Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1));
    IF NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @ResolvedCurrencyId AND IsActive = 1)
        THROW 65008, 'Currency not found or inactive.', 1;

    IF @RateType IS NULL OR @RateType NOT IN (1, 2, 3) THROW 65000, 'Rate type must be Official, Non-official or Market.', 1;
    IF @ExchangeRate IS NOT NULL AND @ExchangeRate <= 0 THROW 65000, 'Exchange rate must be greater than zero.', 1;
    SET @ResolvedRate = COALESCE(@ExchangeRate, masterdata.fn_GetRate(@ResolvedCurrencyId, @RateType, @DocumentDate));
    IF EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @ResolvedCurrencyId AND IsBaseCurrency = 1) SET @ResolvedRate = 1;
    IF @ResolvedRate IS NULL
    BEGIN
        DECLARE @Cur NVARCHAR(3) = (SELECT CurrencyCode FROM masterdata.Currencies WHERE Id = @ResolvedCurrencyId);
        DECLARE @RateMsg NVARCHAR(300) = N'No ' + CASE @RateType WHEN 1 THEN N'official' WHEN 2 THEN N'non-official' ELSE N'market' END
                                       + N' exchange rate is defined for ' + @Cur + N' on or before ' + CONVERT(NVARCHAR(10), @DocumentDate, 120)
                                       + N'. Add one in Master Data > Exchange Rates or enter the rate manually.';
        THROW 65008, @RateMsg, 1;
    END

    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;
    IF @MaxDiscountPercent > 100 SET @MaxDiscountPercent = 100;

    -- Source document rules.
    IF @SourceDocumentId IS NOT NULL
    BEGIN
        DECLARE @SrcType NVARCHAR(20), @SrcStatus TINYINT, @SrcSupplier INT, @SrcBranch INT;
        SELECT @SrcType = dt.Code, @SrcStatus = d.Status, @SrcSupplier = d.SupplierId, @SrcBranch = d.BranchId
        FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceDocumentId;
        IF @SrcType IS NULL THROW 65011, 'Source document not found.', 1;
        IF (@DocumentTypeCode = N'PINV' AND @SrcType <> N'PO') OR (@DocumentTypeCode = N'PRET' AND @SrcType <> N'PINV') OR @DocumentTypeCode = N'PO'
            THROW 65011, 'A purchase invoice can only come from a purchase order and a return from a purchase invoice.', 1;
        IF @SrcStatus <> 2 THROW 65011, 'The source document must be posted (and, for an order, still open).', 1;
        IF @SrcSupplier <> @SupplierId THROW 65011, 'The supplier must be the supplier of the source document.', 1;
        IF @SrcBranch <> @BranchId THROW 65011, 'The branch must be the branch of the source document.', 1;
        IF EXISTS (SELECT 1 FROM @Lines l WHERE l.SourceLineId IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines s WHERE s.Id = l.SourceLineId AND s.DocumentId = @SourceDocumentId))
            THROW 65011, 'A line refers to a source line that does not belong to the source document.', 1;
    END

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
    -- A parent warehouse holds no stock of its own: a line takes a warehouse at the bottom of the tree (script 65).
    IF @Msg IS NULL
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
        FROM @Lines l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
        ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 65000, @Msg, 1;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_ValidateInput
    @DocumentTypeCode NVARCHAR(20),
    @DocumentDate     DATE,
    @BranchId         INT,
    @WarehouseId      INT = NULL,
    @ReasonId         INT,
    @Lines            inventory.tvp_StockDocumentLine READONLY,
    @DocumentTypeId   INT OUTPUT,
    @StockDirection   SMALLINT OUTPUT,
    @CurrencyId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RequiresReason BIT;
    SELECT @DocumentTypeId = Id, @StockDirection = StockDirection, @RequiresReason = RequiresReason
    FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode AND Family = N'Inventory' AND IsActive = 1;
    IF @DocumentTypeId IS NULL
        THROW 62008, 'Document type not found, inactive, or not an inventory document.', 1;

    IF @DocumentDate IS NULL THROW 62000, 'Document Date is required.', 1;
    /* ONE DAY OF TOLERANCE, because this compares a LOCAL date against a UTC one. The date on the
       document is the one the reader sees on their own clock; SYSUTCDATETIME() is the server's in
       UTC. East of Greenwich the two disagree for the first hours after midnight - at 00:20 in
       Beirut (UTC+3) it is still yesterday in UTC, so a document dated today was refused as being
       in the future. A day covers every offset without letting a genuinely future date through by
       more than one. */
    IF @DocumentDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 62000, 'Document Date cannot be in the future.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 62008, 'Branch not found or inactive.', 1;
    IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1)
        THROW 62008, 'The default warehouse must be an active warehouse.', 1;
    IF @RequiresReason = 1 AND @ReasonId IS NULL THROW 62000, 'Reason is required.', 1;
    IF @ReasonId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockReasons
                                             WHERE Id = @ReasonId AND IsActive = 1
                                               AND (AppliesTo = N'Both' OR (AppliesTo = N'In' AND @StockDirection = 1) OR (AppliesTo = N'Out' AND @StockDirection = -1)))
        THROW 62008, 'Reason not found, inactive, or not applicable to this document type.', 1;

    SELECT @CurrencyId = Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1;
    IF @CurrencyId IS NULL THROW 62008, 'No active base currency is configured.', 1;

    -- Per-line checks: the first failing line produces the message.
    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg =
        CASE WHEN i.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item not found.'
             WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
             WHEN iu.Id IS NULL THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': the unit does not belong to item ' + i.ItemCode + N'.'
             WHEN w.Id IS NULL OR w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse not found or inactive.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': quantity must be greater than zero.'
             WHEN l.UnitCost IS NOT NULL AND l.UnitCost < 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': unit cost cannot be negative.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i       ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu  ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    LEFT JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL OR w.Id IS NULL OR w.IsActive = 0
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitCost IS NOT NULL AND l.UnitCost < 0)
    ORDER BY l.LineNumber;

    -- A parent warehouse holds no stock of its own: a line takes a warehouse at the bottom of the tree (script 65).
    IF @Msg IS NULL
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
        FROM @Lines l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
        ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL,
    @AcknowledgeOutOfStock BIT = 0   -- 1 = the user has seen the out-of-stock warning and chose to proceed
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE, @BranchId INT,
                @Rate DECIMAL(18,6), @SourceId INT,
                @PayType TINYINT, @MethodId INT, @AccountId INT, @PayRef NVARCHAR(100), @ClientId INT, @CurId INT, @Total DECIMAL(18,2);

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @Rate = d.ExchangeRate, @SourceId = d.SourceDocumentId,
               @PayType = d.PaymentType, @MethodId = d.ReceiptMethodId, @AccountId = d.ReceiptAccountId, @PayRef = d.PaymentReference,
               @ClientId = d.ClientId, @CurId = d.CurrencyId, @Total = d.TotalAmount
        FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 1 THROW 64010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM sales.SalesDocumentLines WHERE DocumentId = @Id)
            THROW 64009, 'The document has no lines. Add at least one item before posting.', 1;

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.' END
        FROM sales.SalesDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 64000, @Msg, 1;

        -- A parent warehouse holds no stock of its own: a line takes a warehouse at the bottom of the tree (script 65).
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
        FROM sales.SalesDocumentLines l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 64000, @Msg, 1;

        IF NOT EXISTS (SELECT 1 FROM sales.SalesDocuments d INNER JOIN masterdata.Parties p ON p.Id = d.ClientId WHERE d.Id = @Id AND p.IsActive = 1)
            THROW 64008, 'The client is inactive.', 1;

        /* PAYMENT TYPE IS MANDATORY, and a Cash invoice must say where the money went. Judged here, before
           anything moves, so a refusal costs nothing: the account has to hold the invoice's currency
           and be usable by its branch, exactly what the receipt will be checked for a moment later. */
        IF @TypeCode = N'SINV'
        BEGIN
            IF @PayType IS NULL THROW 64000, 'Choose a Payment Type (Cash or On Account) before posting.', 1;
            IF @PayType = 1
            BEGIN
                IF @Total <= 0 THROW 64000, 'A Cash invoice must have a total above zero.', 1;
                IF @MethodId IS NULL THROW 64000, 'A Cash invoice needs a Receipt Method.', 1;
                IF @AccountId IS NULL THROW 64000, 'A Cash invoice needs a Cash / Bank Account.', 1;
                IF NOT EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @MethodId AND IsActive = 1)
                    THROW 64000, 'The receipt method is no longer active.', 1;
                SELECT @Msg = CASE WHEN a.IsActive = 0 THEN N'The account ' + a.AccountCode + N' is no longer active.'
                                   WHEN a.CurrencyId <> @CurId THEN N'The account ' + a.AccountCode + N' holds ' + ac.CurrencyCode
                                        + N', but this invoice is in ' + ic.CurrencyCode + N'. Choose an account in ' + ic.CurrencyCode + N'.'
                                   WHEN a.BranchId IS NOT NULL AND a.BranchId <> @BranchId THEN N'The account ' + a.AccountCode + N' is not available for this invoice''s branch.' END
                FROM masterdata.CashBankAccounts a
                INNER JOIN masterdata.Currencies ac ON ac.Id = a.CurrencyId
                INNER JOIN masterdata.Currencies ic ON ic.Id = @CurId
                WHERE a.Id = @AccountId;
                IF @Msg IS NOT NULL THROW 64000, @Msg, 1;
            END
        END

        -- A return created from an invoice cannot exceed what that invoice line still holds.
        IF @TypeCode = N'SRET' AND @SourceId IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @SourceId AND Status = 2)
                THROW 64010, 'The original invoice is no longer posted.', 1;
            SELECT TOP (1) @Msg = N'Line ' + CAST(x.LineNumber AS NVARCHAR(10)) + N': ' + i.ItemCode + N' - ' + CAST(x.Qty AS NVARCHAR(20))
                                 + N' base units returned but only ' + CAST(s.QuantityBase - s.ReturnedQuantityBase AS NVARCHAR(20)) + N' can still be returned from the invoice line.'
            FROM (SELECT SourceLineId, SUM(QuantityBase) AS Qty, MIN(LineNumber) AS LineNumber FROM sales.SalesDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x
            INNER JOIN sales.SalesDocumentLines s ON s.Id = x.SourceLineId
            INNER JOIN inventory.Items i ON i.Id = s.ItemId
            WHERE x.Qty > s.QuantityBase - s.ReturnedQuantityBase
            ORDER BY x.LineNumber;
            IF @Msg IS NOT NULL THROW 64000, @Msg, 1;
        END

        /* OUT-OF-STOCK POLICY. Every item + warehouse the invoice asks more of than the warehouse holds is a
           SHORTAGE, judged by that warehouse's policy (its own override, else the global setting):
             not allowed          -> refused outright (64007), exactly as before;
             allowed              -> refused with 64016 until the caller confirms (@AcknowledgeOutOfStock = 1),
                                     because the warning is shown even when the setting is on;
             allowed + confirmed  -> posts, stock goes negative, and each shortage is written to the audit. */
        DECLARE @Short TABLE (ItemId INT NOT NULL, WarehouseId INT NOT NULL, ItemCode NVARCHAR(30) NOT NULL, WarehouseCode NVARCHAR(20) NOT NULL,
                              Needed INT NOT NULL, OnHand INT NOT NULL, Allowed BIT NOT NULL, PolicySource NVARCHAR(10) NOT NULL);
        IF @Direction = -1
        BEGIN
            INSERT INTO @Short (ItemId, WarehouseId, ItemCode, WarehouseCode, Needed, OnHand, Allowed, PolicySource)
            SELECT x.ItemId, x.WarehouseId, i.ItemCode, w.WarehouseCode, x.Qty, inventory.fn_StockOnHand(x.ItemId, x.WarehouseId), p.Allowed, p.Source
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            CROSS APPLY sales.fn_OutOfStockPolicy(x.WarehouseId) p
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId);

            SELECT TOP (1) @Msg = N'Insufficient stock for ' + s.ItemCode + N' in ' + s.WarehouseCode + N': available '
                                 + CAST(s.OnHand AS NVARCHAR(20)) + N', required ' + CAST(s.Needed AS NVARCHAR(20)) + N' (base units).'
            FROM @Short s WHERE s.Allowed = 0 ORDER BY s.ItemCode;
            IF @Msg IS NOT NULL THROW 64007, @Msg, 1;

            IF @AcknowledgeOutOfStock = 0 AND EXISTS (SELECT 1 FROM @Short)
            BEGIN
                DECLARE @OosMsg NVARCHAR(2000) =
                    (SELECT N'Out of stock - confirmation required: '
                            + STRING_AGG(s.ItemCode + N' in ' + s.WarehouseCode + N' (available ' + CAST(s.OnHand AS NVARCHAR(20)) + N', selling ' + CAST(s.Needed AS NVARCHAR(20)) + N')', N'; ')
                     FROM @Short s);
                THROW 64016, @OosMsg, 1;
            END
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        -- Frozen cost snapshots: invoices take the moving average; returns keep the original invoice COGS (fallback: average).
        UPDATE l
        SET UnitCostBase = ISNULL(CASE WHEN @Direction = 1 THEN l.UnitCostBase END, ISNULL(i.AverageCost, 0)),
            FobCostAtSale = i.FobCost, LastCostAtSale = i.LastCost
        FROM sales.SalesDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        WHERE l.DocumentId = @Id;

        UPDATE l
        SET NetSalesBase = ROUND(l.LineTotal / @Rate, 2),
            CogsBase = ROUND(l.QuantityBase * l.UnitCostBase, 2),
            GrossProfitBase = ROUND(l.LineTotal / @Rate, 2) - ROUND(l.QuantityBase * l.UnitCostBase, 2),
            GrossProfitPct = CASE WHEN l.LineTotal > 0 THEN ROUND(100.0 * (ROUND(l.LineTotal / @Rate, 2) - ROUND(l.QuantityBase * l.UnitCostBase, 2)) / ROUND(l.LineTotal / @Rate, 2), 2) END
        FROM sales.SalesDocumentLines l
        WHERE l.DocumentId = @Id;

        IF @Direction = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, ISNULL(l.UnitCostBase, 0), NULL FROM sales.SalesDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, NULL, @UserId, 0;
        END

        IF @Direction <> 0
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            -- (48) the branch of the line's warehouse, which need not be the document's branch
            SELECT @MovementDate, l.ItemId, l.WarehouseId, w.BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Sales', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM sales.SalesDocumentLines l
            INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
            WHERE l.DocumentId = @Id;
        END

        -- The confirmed out-of-stock sales, with what the warehouse holds AFTER this invoice (it may be negative).
        IF EXISTS (SELECT 1 FROM @Short)
            INSERT INTO sales.OutOfStockSaleAudit (SalesDocumentId, DocumentNumber, ItemId, ItemCode, WarehouseId, QuantitySold, StockBefore, InventoryAfter, UserId, SaleStatus, PolicySource)
            SELECT @Id, @Number, s.ItemId, s.ItemCode, s.WarehouseId, s.Needed, s.OnHand, inventory.fn_StockOnHand(s.ItemId, s.WarehouseId), @UserId, N'OutOfStockOverride', s.PolicySource
            FROM @Short s;

        IF @TypeCode = N'SRET' AND @SourceId IS NOT NULL
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase + x.Qty
            FROM sales.SalesDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

        UPDATE d
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            TotalCostBase = ISNULL(x.Cost, 0), TotalGrossProfitBase = ISNULL(x.Gp, 0), UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM sales.SalesDocuments d
        CROSS APPLY (SELECT SUM(CogsBase) AS Cost, SUM(GrossProfitBase) AS Gp FROM sales.SalesDocumentLines WHERE DocumentId = @Id) x
        WHERE d.Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM sales.SalesDocumentLines WHERE DocumentId = @Id);
        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s)'
                                + CASE WHEN @Direction <> 0 THEN N' written to the stock ledger' ELSE N'' END, @UserId);

        /* A CASH INVOICE PAYS FOR ITSELF, through the receipt module and not beside it. The invoice is
           already Posted in this transaction (so it can be paid), the receipt is saved against it for
           its whole total at the invoice's own rate (so it balances to the cent) and posted, and the
           link is written. Any refusal throws, which rolls the invoice back too: both or neither. */
        IF @TypeCode = N'SINV' AND @PayType = 1
        BEGIN
            DECLARE @RcLines sales.tvp_ReceiptLine, @RcAllocs sales.tvp_ReceiptAllocation, @ReceiptId INT, @ReceiptNo NVARCHAR(30);
            DECLARE @RcNote NVARCHAR(1000) = N'Automatic receipt for invoice ' + @Number;
            INSERT INTO @RcLines (LineNumber, PaymentMethodId, CurrencyId, Amount, ExchangeRate, CashBankAccountId, Reference)
            VALUES (1, @MethodId, @CurId, @Total, @Rate, @AccountId, @PayRef);
            INSERT INTO @RcAllocs (SalesDocumentId, Amount) VALUES (@Id, @Total);

            EXEC sales.usp_Receipt_Save @Id = NULL, @ReceiptDate = @DocumentDate, @ClientId = @ClientId, @BranchId = @BranchId,
                 @PaymentType = 2, @CurrencyId = @CurId, @Amount = @Total, @ExchangeRate = @Rate, @Notes = @RcNote,
                 @Lines = @RcLines, @Allocations = @RcAllocs, @RowVersion = NULL, @UserId = @UserId, @NewId = @ReceiptId OUTPUT;

            UPDATE sales.Receipts SET SourceSalesDocumentId = @Id WHERE Id = @ReceiptId;
            SELECT @ReceiptNo = ReceiptNumber FROM sales.Receipts WHERE Id = @ReceiptId;
            INSERT INTO sales.ReceiptAudit (ReceiptId, Action, Details, UserId)
            VALUES (@ReceiptId, N'AutoCreated', N'Created automatically by posting invoice ' + @Number, @UserId);

            EXEC sales.usp_Receipt_Post @Id = @ReceiptId, @RowVersion = NULL, @UserId = @UserId;

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'ReceiptPosted', N'Cash sale: receipt ' + @ReceiptNo + N' posted for ' + FORMAT(@Total, N'N2', N'en-US'), @UserId);
        END

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

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

        -- (45) A supplier invoice holds ONE item: a draft saved with several before script 45 is split first.
        IF @TypeCode = N'PINV' AND (SELECT COUNT(DISTINCT ItemId) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id) > 1
        BEGIN
            DECLARE @ItemCount INT = (SELECT COUNT(DISTINCT ItemId) FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id),
                    @ItemCodes NVARCHAR(400);
            SELECT @ItemCodes = STRING_AGG(x.ItemCode, N', ') WITHIN GROUP (ORDER BY x.FirstLine)
            FROM (SELECT TOP (5) i.ItemCode, FirstLine = MIN(l.LineNumber)
                  FROM purchase.PurchaseDocumentLines l INNER JOIN inventory.Items i ON i.Id = l.ItemId
                  WHERE l.DocumentId = @Id
                  GROUP BY l.ItemId, i.ItemCode
                  ORDER BY MIN(l.LineNumber)) x;
            SET @ItemCodes = N'A supplier invoice holds one item. This one has ' + CAST(@ItemCount AS NVARCHAR(10)) + N': ' + @ItemCodes
                         + CASE WHEN @ItemCount > 5 THEN N'...' ELSE N'.' END + N' Create one invoice per item, or use Split by item.';
            THROW 65029, @ItemCodes, 1;
        END
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
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.' END
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 65000, @Msg, 1;

        -- A parent warehouse holds no stock of its own: a line takes a warehouse at the bottom of the tree (script 65).
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
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
            -- (48) the branch of the line's warehouse, which need not be the document's branch
            SELECT @MovementDate, l.ItemId, l.WarehouseId, w.BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Purchase', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM purchase.PurchaseDocumentLines l
            INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
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

CREATE OR ALTER PROCEDURE inventory.usp_StockDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE, @BranchId INT, @ReasonCode NVARCHAR(20);

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @ReasonCode = r.ReasonCode
        FROM inventory.StockDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        LEFT  JOIN inventory.StockReasons r ON r.Id = d.ReasonId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 62006, 'Document not found.', 1;
        IF @Status <> 1 THROW 62010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inventory.StockDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM inventory.StockDocumentLines WHERE DocumentId = @Id)
            THROW 62009, 'The document has no lines. Add at least one item before posting.', 1;

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.' END
        FROM inventory.StockDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

        -- A parent warehouse holds no stock of its own: a line takes a warehouse at the bottom of the tree (script 65).
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.'
        FROM inventory.StockDocumentLines l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 0
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

        IF @Direction = -1
        BEGIN
            UPDATE l SET UnitCost = ISNULL(inventory.fn_AverageCost(l.ItemId), 0) * l.PackingFormula
            FROM inventory.StockDocumentLines l WHERE l.DocumentId = @Id;

            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM inventory.StockDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 62007, @Msg, 1;

            UPDATE d SET TotalCost = x.Cost
            FROM inventory.StockDocuments d
            CROSS APPLY (SELECT ISNULL(SUM(LineTotal), 0) AS Cost FROM inventory.StockDocumentLines WHERE DocumentId = @Id) x
            WHERE d.Id = @Id;
        END

        IF @Number IS NULL
            EXEC inventory.usp_DocumentType_NextNumber @TypeCode, @Number OUTPUT, @BranchId;

        IF @Direction = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, CASE WHEN l.PackingFormula > 0 THEN l.UnitCost / l.PackingFormula ELSE l.UnitCost END, NULL
            FROM inventory.StockDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, NULL, @UserId, 0;      -- average yes, last / FOB cost no
        END

        DECLARE @MovementDate DATETIME2(3) =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
        SELECT @MovementDate, l.ItemId, l.WarehouseId, w.BranchId, @Direction * l.QuantityBase,
               CASE WHEN l.PackingFormula > 0 THEN l.UnitCost / l.PackingFormula END,
               N'Inventory', @TypeCode, @Id, l.Id, @Number, @ReasonCode, l.ExpiryDate, @UserId
        FROM inventory.StockDocumentLines l
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id;

        UPDATE inventory.StockDocuments
        SET DocumentNumber = @Number, Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM inventory.StockDocumentLines WHERE DocumentId = @Id);
        INSERT INTO inventory.StockDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@Id, N'Posted', N'Posted as ' + @Number + N' - ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s) written to the stock ledger', @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_Validate
    @BranchId            INT,
    @DefaultWarehouseId  INT,
    @PriceListId         INT           = NULL,  -- NULL = cost mode (inventory / purchase): Unit Price column = cost, no price list checks
    @AllowPriceOverride  BIT           = 0,
    @MaxDiscountPercent  DECIMAL(9,4)  = 100,
    @Rows                sales.tvp_InvoiceImportRow READONLY,
    @CheckStock          BIT           = 0,     -- 1 = cumulative stock check per item + warehouse (outgoing documents)
    @DocumentTypeCode    NVARCHAR(20)  = NULL   -- the page's document type; rows for another type become Errors
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 61008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsActive = 1)
        THROW 61008, 'The default warehouse is not an active warehouse.', 1;
    IF masterdata.fn_Warehouse_IsLeaf(@DefaultWarehouseId) = 0
        THROW 61008, 'The default warehouse has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.', 1;
    IF @PriceListId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1)
        THROW 61008, 'Price list not found or inactive.', 1;
    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;
    SET @CheckStock = ISNULL(@CheckStock, 0);
    SET @DocumentTypeCode = NULLIF(LTRIM(RTRIM(@DocumentTypeCode)), N'');

    DECLARE @PageTypeName NVARCHAR(100), @Family NVARCHAR(20);
    IF @DocumentTypeCode IS NOT NULL
    BEGIN
        SELECT @PageTypeName = Name, @Family = Family FROM inventory.DocumentTypes WHERE Code = @DocumentTypeCode;
        IF @PageTypeName IS NULL THROW 61008, 'Document type not found.', 1;
    END
    -- Unit preference: 1 = sales unit first, 2 = purchase unit first, 0 = base unit first.
    DECLARE @UnitPref TINYINT = CASE WHEN @Family = N'Sales' OR (@Family IS NULL AND @PriceListId IS NOT NULL) THEN 1
                                     WHEN @Family = N'Purchase' THEN 2 ELSE 0 END;

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    ;WITH resolved AS
    (
        SELECT r.RowNumber,
               ItemRef      = NULLIF(LTRIM(RTRIM(r.ItemRef)), N''),
               UnitName     = NULLIF(LTRIM(RTRIM(r.UnitName)), N''),
               WarehouseRef = NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N''),
               r.Quantity, r.RawQuantity, ManualPrice = r.UnitPrice, r.DiscountPercent, r.ExpiryDate, r.RawExpiryDate,
               Notes        = NULLIF(LTRIM(RTRIM(r.Notes)), N''),
               RowTypeRef   = NULLIF(LTRIM(RTRIM(r.DocumentTypeCode)), N''),
               rt.RowTypeCode, rt.RowTypeName,
               it.ItemId, it.ItemCode, it.ItemName, it.ItemActive, it.BarcodeUnitId,
               u.ItemUnitId, u.UnitTypeName, u.PackingFormula,
               w.WarehouseId, w.WarehouseCode, w.WarehouseName, w.WarehouseActive, w.WarehouseBranchId,
               pr.BranchPrice, pr.AllBranchesPrice
        FROM @Rows r
        OUTER APPLY
        (
            SELECT TOP (1) dt.Code AS RowTypeCode, dt.Name AS RowTypeName
            FROM inventory.DocumentTypes dt
            WHERE NULLIF(LTRIM(RTRIM(r.DocumentTypeCode)), N'') IS NOT NULL
              AND (dt.Code = LTRIM(RTRIM(r.DocumentTypeCode)) OR dt.Name = LTRIM(RTRIM(r.DocumentTypeCode)))
            ORDER BY CASE WHEN dt.Code = LTRIM(RTRIM(r.DocumentTypeCode)) THEN 0 ELSE 1 END
        ) rt
        OUTER APPLY
        (
            SELECT TOP (1) i.Id AS ItemId, i.ItemCode, i.ItemName, i.IsActive AS ItemActive, bu.Id AS BarcodeUnitId
            FROM inventory.Items i
            LEFT JOIN inventory.ItemUnits bu ON bu.ItemId = i.Id AND bu.Barcode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'')
            WHERE i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') OR bu.Id IS NOT NULL
            ORDER BY CASE WHEN i.ItemCode = NULLIF(LTRIM(RTRIM(r.ItemRef)), N'') THEN 0 ELSE 1 END
        ) it
        OUTER APPLY
        (
            SELECT TOP (1) iu.Id AS ItemUnitId, t.UnitTypeName, iu.PackingFormula
            FROM inventory.ItemUnits iu
            INNER JOIN masterdata.UnitTypes t ON t.Id = iu.UnitTypeId
            WHERE iu.ItemId = it.ItemId
              AND (   (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NOT NULL
                       AND (t.UnitTypeName = LTRIM(RTRIM(r.UnitName)) OR iu.SkuCode = LTRIM(RTRIM(r.UnitName))))
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NOT NULL AND iu.Id = it.BarcodeUnitId)
                   OR (NULLIF(LTRIM(RTRIM(r.UnitName)), N'') IS NULL AND it.BarcodeUnitId IS NULL))
            ORDER BY CASE @UnitPref WHEN 1 THEN CASE WHEN iu.IsSalesUnit = 1 THEN 0 ELSE 1 END
                                    WHEN 2 THEN CASE WHEN iu.IsPurchaseUnit = 1 THEN 0 ELSE 1 END
                                    ELSE CASE WHEN iu.IsBaseUnit = 1 THEN 0 ELSE 1 END END,
                     iu.IsBaseUnit DESC, iu.PackingFormula
        ) u
        OUTER APPLY
        (
            SELECT TOP (1) wh.Id AS WarehouseId, wh.WarehouseCode, wh.WarehouseName, wh.IsActive AS WarehouseActive, wh.BranchId AS WarehouseBranchId
            FROM masterdata.Warehouses wh
            WHERE (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NOT NULL
                   AND (wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) OR wh.WarehouseName = LTRIM(RTRIM(r.WarehouseRef))))
               OR (NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N'') IS NULL AND wh.Id = @DefaultWarehouseId)
            ORDER BY CASE WHEN wh.WarehouseCode = LTRIM(RTRIM(r.WarehouseRef)) THEN 0 ELSE 1 END
        ) w
        OUTER APPLY
        (
            SELECT BranchPrice      = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId = @BranchId AND IsActive = 1),
                   AllBranchesPrice = (SELECT TOP (1) Price FROM masterdata.UnitPrices
                                       WHERE ItemUnitId = u.ItemUnitId AND PriceListId = @PriceListId AND BranchId IS NULL AND IsActive = 1)
        ) pr
    ),
    stocked AS
    (
        SELECT x.*,
               QtyBase    = CASE WHEN x.ItemUnitId IS NOT NULL AND x.Quantity IS NOT NULL AND x.Quantity > 0 AND x.Quantity = FLOOR(x.Quantity)
                                 THEN CAST(x.Quantity AS INT) * x.PackingFormula ELSE 0 END,
               OnHandBase = CASE WHEN x.ItemId IS NOT NULL AND x.WarehouseId IS NOT NULL THEN inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) END,
               AllowOos   = CASE WHEN x.WarehouseId IS NOT NULL THEN (SELECT p.Allowed FROM sales.fn_OutOfStockPolicy(x.WarehouseId) p) END
        FROM resolved x
    ),
    running AS
    (
        SELECT s.*,
               RequiredBase = SUM(s.QtyBase) OVER (PARTITION BY s.ItemId, s.WarehouseId ORDER BY s.RowNumber ROWS UNBOUNDED PRECEDING),
               EarlierRows  = STUFF((SELECT N', ' + CAST(s2.RowNumber AS NVARCHAR(10))
                                     FROM stocked s2
                                     WHERE s2.ItemId = s.ItemId AND s2.WarehouseId = s.WarehouseId AND s2.QtyBase > 0 AND s2.RowNumber < s.RowNumber
                                     ORDER BY s2.RowNumber FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N'')
        FROM stocked s
    ),
    judged AS
    (
        SELECT x.*,
               SystemPrice = COALESCE(x.BranchPrice, x.AllBranchesPrice),
               EffectiveDiscount = ISNULL(x.DiscountPercent, 0),
               Err0 = CASE WHEN x.RowTypeRef IS NOT NULL AND x.RowTypeCode IS NULL THEN N'Document Type ''' + x.RowTypeRef + N''' does not exist.'
                           WHEN x.RowTypeCode IS NOT NULL AND @DocumentTypeCode IS NOT NULL AND x.RowTypeCode <> @DocumentTypeCode
                                THEN N'This row is for ' + x.RowTypeName + N' (' + x.RowTypeCode + N'), not for ' + @PageTypeName + N'.' END,
               Err1 = CASE WHEN x.ItemRef IS NULL THEN N'Item Code / Barcode is required.'
                           WHEN x.ItemId IS NULL THEN N'Item Code ' + x.ItemRef + N' does not exist.'
                           WHEN x.ItemActive = 0 THEN N'Item ' + x.ItemCode + N' is inactive.' END,
               Err2 = CASE WHEN x.Quantity IS NULL AND x.RawQuantity IS NOT NULL THEN N'Quantity ''' + x.RawQuantity + N''' is not a number.'
                           WHEN x.Quantity IS NULL OR x.Quantity <= 0 THEN N'Quantity must be greater than zero.'
                           WHEN x.Quantity <> FLOOR(x.Quantity) THEN N'Quantity must be a whole number of pieces.' END,
               Err3 = CASE WHEN x.ItemId IS NOT NULL AND x.UnitName IS NOT NULL AND x.ItemUnitId IS NULL
                                THEN N'Unit ''' + x.UnitName + N''' is not configured for Item ' + x.ItemCode + N'.'
                           WHEN x.ItemId IS NOT NULL AND x.ItemUnitId IS NULL THEN N'Item ' + x.ItemCode + N' has no units configured.' END,
               Err4 = CASE WHEN x.WarehouseRef IS NOT NULL AND x.WarehouseId IS NULL THEN N'Warehouse ' + x.WarehouseRef + N' does not exist.'
                           WHEN x.WarehouseActive = 0 THEN N'Warehouse ' + x.WarehouseCode + N' is inactive.'
                           WHEN masterdata.fn_Warehouse_IsLeaf(x.WarehouseId) = 0 THEN N'Warehouse ' + x.WarehouseCode + N' has warehouses under it: choose one of those.' END,
               Err5 = CASE WHEN @PriceListId IS NOT NULL AND x.ItemUnitId IS NOT NULL
                            AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NULL
                            AND NOT (x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1)
                                THEN N'No selling price was found for Item ' + x.ItemCode + N', Unit ' + x.UnitTypeName + N', and the selected Price List.'
                           WHEN x.ManualPrice IS NOT NULL AND x.ManualPrice < 0 THEN N'Unit Price cannot be negative.' END,
               Err6 = CASE WHEN ISNULL(x.DiscountPercent, 0) < 0 OR ISNULL(x.DiscountPercent, 0) > @MaxDiscountPercent
                                THEN N'Discount % must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(20)) + N'.' END,
               Err7 = CASE WHEN x.ExpiryDate IS NULL AND x.RawExpiryDate IS NOT NULL THEN N'Expiry Date ''' + x.RawExpiryDate + N''' is not a valid date.' END,
               Err8 = CASE WHEN @CheckStock = 1 AND NOT (@DocumentTypeCode = N'SINV' AND ISNULL(x.AllowOos, 0) = 1) AND x.QtyBase > 0 AND x.WarehouseId IS NOT NULL AND x.RequiredBase > ISNULL(x.OnHandBase, 0)
                                THEN N'Insufficient stock for ' + x.ItemCode + N' in ' + x.WarehouseCode + N': available ' + CAST(ISNULL(x.OnHandBase, 0) AS NVARCHAR(20))
                                     + N', required ' + CAST(x.RequiredBase AS NVARCHAR(20))
                                     + CASE WHEN x.EarlierRows IS NULL THEN N'' ELSE N' (with rows ' + x.EarlierRows + N')' END + N'.' END,
               Warn4 = CASE WHEN @CheckStock = 1 AND @DocumentTypeCode = N'SINV' AND ISNULL(x.AllowOos, 0) = 1 AND x.QtyBase > 0 AND x.WarehouseId IS NOT NULL
                             AND x.RequiredBase > ISNULL(x.OnHandBase, 0)
                                THEN N'Out of stock: ' + x.ItemCode + N' in ' + x.WarehouseCode + N' - available ' + CAST(ISNULL(x.OnHandBase, 0) AS NVARCHAR(20))
                                     + N', selling ' + CAST(x.RequiredBase AS NVARCHAR(20)) + N'. Posting will ask you to confirm.' END,
               Warn1 = CASE WHEN @PriceListId IS NOT NULL AND x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 0 AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NOT NULL
                                THEN N'Manual price ignored - system price ' + CAST(COALESCE(x.BranchPrice, x.AllBranchesPrice) AS NVARCHAR(30)) + N' used (no price override permission).' END,
               Warn2 = CASE WHEN x.ExpiryDate IS NOT NULL AND x.ExpiryDate < @Today THEN N'Expiry date is in the past.' END,
               Warn3 = CASE WHEN @UnitPref = 1 AND x.UnitName IS NULL AND x.BarcodeUnitId IS NULL AND x.ItemUnitId IS NOT NULL
                             AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits s WHERE s.ItemId = x.ItemId AND s.IsSalesUnit = 1)
                                THEN N'No sales unit is flagged for this item - the base unit was used.'
                            WHEN @UnitPref = 2 AND x.UnitName IS NULL AND x.BarcodeUnitId IS NULL AND x.ItemUnitId IS NOT NULL
                             AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits s WHERE s.ItemId = x.ItemId AND s.IsPurchaseUnit = 1)
                                THEN N'No purchase unit is flagged for this item - the base unit was used.' END
        FROM running x
    )
    SELECT j.RowNumber,
           Status  = CASE WHEN COALESCE(j.Err0, j.Err1, j.Err2, j.Err3, j.Err4, j.Err5, j.Err6, j.Err7, j.Err8) IS NOT NULL THEN N'Error'
                          WHEN COALESCE(j.Warn1, j.Warn2, j.Warn3, j.Warn4) IS NOT NULL THEN N'Warning'
                          ELSE N'Valid' END,
           Message = NULLIF(LTRIM(CONCAT(ISNULL(j.Err0 + N' ', N''), ISNULL(j.Err1 + N' ', N''), ISNULL(j.Err2 + N' ', N''), ISNULL(j.Err3 + N' ', N''), ISNULL(j.Err4 + N' ', N''),
                                         ISNULL(j.Err5 + N' ', N''), ISNULL(j.Err6 + N' ', N''), ISNULL(j.Err7 + N' ', N''), ISNULL(j.Err8 + N' ', N''),
                                         ISNULL(j.Warn1 + N' ', N''), ISNULL(j.Warn2 + N' ', N''), ISNULL(j.Warn3 + N' ', N''), ISNULL(j.Warn4, N''))), N''),
           RowDocumentTypeCode = ISNULL(j.RowTypeCode, @DocumentTypeCode),
           j.ItemRef, j.ItemId, j.ItemCode, j.ItemName,
           j.ItemUnitId, j.UnitTypeName, j.PackingFormula,
           j.WarehouseId, j.WarehouseCode, j.WarehouseName,
           Quantity    = CASE WHEN j.Quantity IS NOT NULL AND j.Quantity > 0 AND j.Quantity = FLOOR(j.Quantity) THEN CAST(j.Quantity AS INT) END,
           UnitPrice   = CASE WHEN @PriceListId IS NULL THEN j.ManualPrice
                              WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN j.ManualPrice
                              ELSE j.SystemPrice END,
           PriceSource = CASE WHEN @PriceListId IS NULL THEN CASE WHEN j.ManualPrice IS NOT NULL THEN N'Manual' END
                              WHEN j.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1 THEN N'Manual'
                              WHEN j.BranchPrice IS NOT NULL THEN N'Branch'
                              WHEN j.AllBranchesPrice IS NOT NULL THEN N'AllBranches' END,
           ManualPrice = j.ManualPrice,
           DiscountPercent = j.EffectiveDiscount,
           j.ExpiryDate, j.Notes,
           j.OnHandBase, j.RequiredBase
    FROM judged j
    ORDER BY j.RowNumber;
END
GO

CREATE OR ALTER PROCEDURE logistics.usp_Container_Offload
    @Id            INT,
    @Lines         logistics.tvp_ContainerReceipt READONLY,   -- empty = everything received as loaded
    @OffloadedDate DATE      = NULL,
    @WarehouseId   INT       = NULL,                          -- NULL = the container's warehouse
    @RowVersion    BINARY(8) = NULL,
    @UserId        INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @OffloadedDate IS NULL SET @OffloadedDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Status TINYINT, @BranchId INT, @Ref NVARCHAR(30), @CtWarehouse INT;
    SELECT @Status = Status, @BranchId = BranchId, @Ref = ContainerRef, @CtWarehouse = WarehouseId
    FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;

    IF @Status IS NULL THROW 69006, 'Container not found.', 1;
    IF @Status IN (6, 7) THROW 69011, 'This container is already offloaded.', 1;
    IF @Status = 1 THROW 69010, 'Confirm the container before offloading it.', 1;
    IF @Status = 8 THROW 69010, 'A cancelled container cannot be offloaded.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;

    IF @WarehouseId IS NULL SET @WarehouseId = @CtWarehouse;
    IF @WarehouseId IS NULL THROW 69000, 'The offloading warehouse is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 69000, 'The offloading warehouse is inactive or does not belong to the container branch.', 1;
    IF masterdata.fn_Warehouse_IsLeaf(@WarehouseId) = 0
        THROW 69000, 'The offloading warehouse has warehouses under it. Choose one of those: stock is kept only in the warehouses at the bottom of the tree.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.ContainerLines WHERE ContainerId = @Id)
        THROW 69009, 'The container has no items.', 1;

    DECLARE @Msg NVARCHAR(400);

    SELECT TOP (1) @Msg = N'Movement ' + m.MovementNo + N' of this container is still in progress. Complete it before offloading.'
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
    WHERE mc.ContainerId = @Id AND m.Status = 2
    ORDER BY m.MovementNo;
    IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

    SELECT TOP (1) @Msg = N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N' (' + i.ItemCode + N'): ' + CAST(cl.QuantityBase AS NVARCHAR(20))
                          + N' loaded but ' + CAST(ISNULL(q.Posted, 0) AS NVARCHAR(20)) + N' invoiced by posted invoices'
                          + CASE WHEN ISNULL(q.Draft, 0) > 0 THEN N' (' + CAST(q.Draft AS NVARCHAR(20)) + N' in draft invoices)' ELSE N'' END
                          + N'. Every line must be invoiced and the invoices posted before the offload.'
    FROM logistics.ContainerLines cl
    INNER JOIN inventory.Items i ON i.Id = cl.ItemId
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase END),
                        Draft  = SUM(CASE WHEN d.Status = 1 THEN pil.QuantityBase END)
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id) q
    WHERE cl.ContainerId = @Id AND ISNULL(q.Posted, 0) <> cl.QuantityBase
    ORDER BY cl.LineNumber;
    IF @Msg IS NOT NULL THROW 69016, @Msg, 1;

    SELECT TOP (1) @Msg =
        CASE WHEN cl.Id IS NULL THEN N'A received line does not belong to this container.'
             WHEN r.ReceivedQuantityBase < 0 THEN N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': the received quantity cannot be negative.'
             WHEN r.ReceivedQuantityBase > cl.QuantityBase THEN N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': received '
                  + CAST(r.ReceivedQuantityBase AS NVARCHAR(20)) + N' but only ' + CAST(cl.QuantityBase AS NVARCHAR(20)) + N' were loaded.'
             ELSE N'Line ' + CAST(cl.LineNumber AS NVARCHAR(10)) + N': a reason is required when the received quantity differs from the loaded quantity.'
             END
    FROM @Lines r
    LEFT JOIN logistics.ContainerLines cl ON cl.Id = r.LineId AND cl.ContainerId = @Id
    WHERE cl.Id IS NULL OR r.ReceivedQuantityBase < 0 OR r.ReceivedQuantityBase > cl.QuantityBase
       OR (r.ReceivedQuantityBase <> cl.QuantityBase AND NULLIF(LTRIM(RTRIM(r.VarianceReason)), N'') IS NULL)
    ORDER BY cl.LineNumber;
    IF @Msg IS NOT NULL THROW 69000, @Msg, 1;

    -- a manual share of a posted charge cannot sit on a line that receives nothing (it could not enter any cost)
    SELECT TOP (1) @Msg = N'The posted charge ' + t.ChargeName + N' has a manual share on line ' + CAST(cl.LineNumber AS NVARCHAR(10))
                          + N' (' + i.ItemCode + N'), which receives nothing. Cancel that charge and enter it again on the received lines.'
    FROM logistics.ContainerChargeAllocations a
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId AND ch.Status = 2 AND ch.IncludeInLandedCost = 1 AND a.IsManual = 1
    INNER JOIN purchase.ChargeTypes t        ON t.Id = ch.ChargeTypeId
    INNER JOIN logistics.ContainerLines cl   ON cl.Id = a.ContainerLineId
    INNER JOIN inventory.Items i             ON i.Id = cl.ItemId
    LEFT  JOIN @Lines r                      ON r.LineId = cl.Id
    WHERE ch.ContainerId = @Id AND a.AmountBase > 0 AND ISNULL(r.ReceivedQuantityBase, cl.QuantityBase) = 0
    ORDER BY cl.LineNumber;
    IF @Msg IS NOT NULL THROW 70013, @Msg, 1;

    -- every offload has its own number in the ledger (KTG-2026-0001, then KTG-2026-0001/2 after a reversal)
    DECLARE @OffloadNo INT = 1 + (SELECT COUNT(DISTINCT m.DocumentNumber) FROM inventory.StockMovements m
                                  WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id AND m.IsReversal = 0);
    DECLARE @Tag NVARCHAR(30) = LEFT(@Ref + CASE WHEN @OffloadNo > 1 THEN N'/' + CAST(@OffloadNo AS NVARCHAR(10)) ELSE N'' END, 30);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE cl
        SET ReceivedQuantityBase = ISNULL(r.ReceivedQuantityBase, cl.QuantityBase),
            VarianceReason = NULLIF(LTRIM(RTRIM(r.VarianceReason)), N''),
            FobCostBase = f.Fob
        FROM logistics.ContainerLines cl
        LEFT JOIN @Lines r ON r.LineId = cl.Id
        OUTER APPLY (SELECT Fob = SUM(pil.FobCostBase * pil.QuantityBase) / NULLIF(SUM(pil.QuantityBase), 0)
                     FROM purchase.PurchaseDocumentLines pil
                     INNER JOIN purchase.PurchaseDocuments d ON d.Id = pil.DocumentId
                     WHERE pil.ContainerLineId = cl.Id AND d.Status IN (2, 4)) f
        WHERE cl.ContainerId = @Id;

        -- the posted charges follow the real quantities and values, then they are frozen in the cost of the goods
        EXEC logistics.usp_Container_ReallocateCharges @Id, 0;
        UPDATE logistics.ContainerCharges SET AppliedAtOffload = 1
        WHERE ContainerId = @Id AND Status = 2 AND IncludeInLandedCost = 1;
        EXEC logistics.usp_Container_RecalcCosts @Id;

        DECLARE @Rec TABLE (LineId INT PRIMARY KEY, ItemId INT, SupplierId INT, QuantityBase INT,
                            UnitCostBase DECIMAL(18,6), FobCostBase DECIMAL(18,6), ExpiryDate DATE);
        INSERT INTO @Rec (LineId, ItemId, SupplierId, QuantityBase, UnitCostBase, FobCostBase, ExpiryDate)
        SELECT cl.Id, cl.ItemId, po.SupplierId, cl.ReceivedQuantityBase, ISNULL(cl.LandedCostBase, 0), cl.FobCostBase,
               (SELECT MIN(pil.ExpiryDate) FROM purchase.PurchaseDocumentLines pil
                INNER JOIN purchase.PurchaseDocuments d ON d.Id = pil.DocumentId
                WHERE pil.ContainerLineId = cl.Id AND d.Status IN (2, 4))
        FROM logistics.ContainerLines cl
        INNER JOIN purchase.PurchaseDocuments po ON po.Id = cl.PurchaseOrderId
        WHERE cl.ContainerId = @Id AND cl.ReceivedQuantityBase > 0;

        DECLARE @MovementDate DATETIME2(3) =
            DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@OffloadedDate AS DATETIME2(3)));

        -- per supplier (last supplier / last cost follow the supplier of the goods): moving average first, then the
        -- movements of that supplier, so the next supplier's average sees them
        DECLARE @SupplierId INT;
        DECLARE @R inventory.tvp_ItemReceipt;
        DECLARE suppliers CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT SupplierId FROM @Rec;
        OPEN suppliers;
        FETCH NEXT FROM suppliers INTO @SupplierId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DELETE FROM @R;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT ItemId, QuantityBase, UnitCostBase, FobCostBase FROM @Rec WHERE SupplierId = @SupplierId;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId, 1;

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, r.ItemId, @WarehouseId, @BranchId, r.QuantityBase, r.UnitCostBase,
                   N'Purchase', N'CNT', @Id, r.LineId, @Tag, NULL, r.ExpiryDate, @UserId
            FROM @Rec r
            WHERE r.SupplierId = @SupplierId;

            FETCH NEXT FROM suppliers INTO @SupplierId;
        END
        CLOSE suppliers;
        DEALLOCATE suppliers;

        -- the invoice lines are received, in posting order, for what actually arrived
        WITH x AS
        (
            SELECT pil.Id, pil.QuantityBase, Rec = ISNULL(cl.ReceivedQuantityBase, 0),
                   Before = ISNULL(SUM(pil.QuantityBase) OVER (PARTITION BY cl.Id ORDER BY d.PostedAtUtc, pil.Id
                                                               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
            FROM logistics.ContainerLines cl
            INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
            INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId AND d.Status IN (2, 4)
            WHERE cl.ContainerId = @Id
        )
        UPDATE pl
        SET ReceivedQuantityBase = pl.ReceivedQuantityBase
                                 + CASE WHEN x.Rec - x.Before <= 0 THEN 0
                                        WHEN x.Rec - x.Before >= x.QuantityBase THEN x.QuantityBase
                                        ELSE x.Rec - x.Before END
        FROM purchase.PurchaseDocumentLines pl
        INNER JOIN x ON x.Id = pl.Id;

        UPDATE logistics.Containers
        SET OffloadedDate = @OffloadedDate, OffloadedAtUtc = SYSUTCDATETIME(), OffloadedBy = @UserId,
            WarehouseId = @WarehouseId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        EXEC logistics.usp_Container_RefreshStatus @Id;

        DECLARE @Total INT = (SELECT ISNULL(SUM(QuantityBase), 0) FROM @Rec);
        DECLARE @Short INT = (SELECT COUNT(*) FROM logistics.ContainerLines WHERE ContainerId = @Id AND ReceivedQuantityBase < QuantityBase);
        DECLARE @Value DECIMAL(18,2) = (SELECT ISNULL(SUM(QuantityBase * UnitCostBase), 0) FROM @Rec);
        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@Id, N'Offloaded', LEFT(@Tag + N': received ' + CAST(@Total AS NVARCHAR(20)) + N' base unit(s) into '
                + (SELECT WarehouseCode FROM masterdata.Warehouses WHERE Id = @WarehouseId)
                + N' at a landed value of ' + CAST(@Value AS NVARCHAR(30))
                + CASE WHEN @Short > 0 THEN N'; ' + CAST(@Short AS NVARCHAR(10)) + N' line(s) short-shipped' ELSE N'' END, 500), @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

PRINT 'Script 65 applied: document lines take a warehouse at the bottom of the tree, of any branch.';
GO
