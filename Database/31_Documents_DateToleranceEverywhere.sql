/* ==================================================================================================
   31: Inventory and purchase - the same day of date tolerance the sales invoice got
   --------------------------------------------------------------------------------------------------
   Script 30 gave sales.usp_SalesDocument_ValidateInput a day of tolerance on the document date,
   because the check compared a LOCAL date against a UTC one: at 00:20 in Beirut (UTC+3) it is still
   yesterday in UTC, so a document dated today was refused as being in the future.

   The same line sat in the inventory and purchase validators, so the same thing happened on an
   Inventory In and on a purchase invoice after midnight. They now match the sales rule.

   Nothing else in either procedure changes.
   ================================================================================================== */

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
    IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 62008, 'The default warehouse must be an active warehouse of the selected branch.', 1;
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
             WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not available for the selected branch.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': quantity must be greater than zero.'
             WHEN l.UnitCost IS NOT NULL AND l.UnitCost < 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': unit cost cannot be negative.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i       ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu  ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    LEFT JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL OR w.Id IS NULL OR w.IsActive = 0 OR w.BranchId <> @BranchId
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitCost IS NOT NULL AND l.UnitCost < 0)
    ORDER BY l.LineNumber;

    IF @Msg IS NOT NULL THROW 62000, @Msg, 1;
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
    IF @WarehouseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 65008, 'The default warehouse must be an active warehouse of the selected branch.', 1;
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
             WHEN w.BranchId <> @BranchId THEN N'warehouse ' + w.WarehouseCode + N' is not available for the selected branch.'
             WHEN l.Quantity IS NULL OR l.Quantity <= 0 THEN N'quantity must be greater than zero.'
             WHEN l.UnitPrice IS NOT NULL AND l.UnitPrice < 0 THEN N'unit price cannot be negative.'
             WHEN l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent)
                  THEN N'discount must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(12)) + N'%.'
        END
    FROM @Lines l
    LEFT JOIN inventory.Items i      ON i.Id = l.ItemId
    LEFT JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
    LEFT JOIN masterdata.Warehouses w  ON w.Id = l.WarehouseId
    WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL OR w.Id IS NULL OR w.IsActive = 0 OR w.BranchId <> @BranchId
       OR l.Quantity IS NULL OR l.Quantity <= 0 OR (l.UnitPrice IS NOT NULL AND l.UnitPrice < 0)
       OR (l.DiscountPercent IS NOT NULL AND (l.DiscountPercent < 0 OR l.DiscountPercent > @MaxDiscountPercent))
    ORDER BY l.LineNumber;
    IF @Msg IS NOT NULL THROW 65000, @Msg, 1;
END
GO

