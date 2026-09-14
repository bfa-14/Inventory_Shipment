/* =====================================================================================
   Inventory_Shipment - 18: Excel import validation checks STOCK (for "validate -> post to stock")

   RE-CREATES sales.usp_InvoiceImport_Validate (scripts 14/15) with one new parameter and two new
   output columns - everything else is unchanged:
     @CheckStock BIT = 0   1 = rows that would take more than the stock on hand become Errors.
                            The check is CUMULATIVE in file order per item + warehouse (row 5 for the
                            same item/warehouse as row 2 sees what row 2 already takes), in BASE units.
     OnHandBase            stock on hand for the row's item + warehouse (base units) - shown in the preview
     RequiredBase          base units required by this row plus the rows above it for the same item + warehouse

   Message: "Insufficient stock for TVS-AP160 in WH-001: available 3, required 5 (rows 2, 5)."
   Used by the "Import Sales from Excel" page: validate (with stock) -> preview -> post as a Sales Invoice
   (script 17: usp_SalesDocument_Save + usp_SalesDocument_Post) -> stock movements.

   Requires 15 (ledger) and 17 (sales documents). Idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'inventory.fn_StockOnHand', N'FN') IS NULL OR OBJECT_ID(N'sales.usp_SalesDocument_Post', N'P') IS NULL
BEGIN
    RAISERROR ('Run scripts 15 and 17 before this script.', 16, 1);
    RETURN;
END
GO

CREATE OR ALTER PROCEDURE sales.usp_InvoiceImport_Validate
    @BranchId            INT,
    @DefaultWarehouseId  INT,
    @PriceListId         INT           = NULL,  -- NULL = stock document: no pricing, Unit Price column = unit cost (optional)
    @AllowPriceOverride  BIT           = 0,
    @MaxDiscountPercent  DECIMAL(9,4)  = 100,
    @Rows                sales.tvp_InvoiceImportRow READONLY,
    @CheckStock          BIT           = 0      -- 1 = quantities are checked against the stock on hand (cumulative per item + warehouse)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 61008, 'Branch not found or inactive.', 1;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @DefaultWarehouseId AND IsActive = 1 AND BranchId = @BranchId)
        THROW 61008, 'The default warehouse is not an active warehouse of the selected branch.', 1;
    IF @PriceListId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @PriceListId AND IsActive = 1)
        THROW 61008, 'Price list not found or inactive.', 1;
    IF @MaxDiscountPercent IS NULL OR @MaxDiscountPercent < 0 SET @MaxDiscountPercent = 0;
    SET @CheckStock = ISNULL(@CheckStock, 0);

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    ;WITH resolved AS
    (
        SELECT r.RowNumber,
               ItemRef      = NULLIF(LTRIM(RTRIM(r.ItemRef)), N''),
               UnitName     = NULLIF(LTRIM(RTRIM(r.UnitName)), N''),
               WarehouseRef = NULLIF(LTRIM(RTRIM(r.WarehouseRef)), N''),
               r.Quantity, r.RawQuantity, ManualPrice = r.UnitPrice, r.DiscountPercent, r.ExpiryDate, r.RawExpiryDate,
               Notes        = NULLIF(LTRIM(RTRIM(r.Notes)), N''),
               it.ItemId, it.ItemCode, it.ItemName, it.ItemActive, it.BarcodeUnitId,
               u.ItemUnitId, u.UnitTypeName, u.PackingFormula,
               w.WarehouseId, w.WarehouseCode, w.WarehouseName, w.WarehouseActive, w.WarehouseBranchId,
               pr.BranchPrice, pr.AllBranchesPrice
        FROM @Rows r
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
            ORDER BY CASE WHEN @PriceListId IS NULL THEN CASE WHEN iu.IsBaseUnit = 1 THEN 0 ELSE 1 END       -- stock docs: base unit first
                          ELSE CASE WHEN iu.IsSalesUnit = 1 THEN 0 ELSE 1 END END, iu.IsBaseUnit DESC, iu.PackingFormula
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
        -- Base units required by this row (0 when the row cannot be quantified) and the running total per item + warehouse.
        SELECT x.*,
               QtyBase      = CASE WHEN x.ItemUnitId IS NOT NULL AND x.Quantity IS NOT NULL AND x.Quantity > 0 AND x.Quantity = FLOOR(x.Quantity)
                                   THEN CAST(x.Quantity AS INT) * x.PackingFormula ELSE 0 END,
               OnHandBase   = CASE WHEN x.ItemId IS NOT NULL AND x.WarehouseId IS NOT NULL THEN inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) END
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
                           WHEN x.WarehouseBranchId <> @BranchId THEN N'Warehouse ' + x.WarehouseCode + N' is not available for the selected branch.' END,
               Err5 = CASE WHEN @PriceListId IS NOT NULL AND x.ItemUnitId IS NOT NULL
                            AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NULL
                            AND NOT (x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 1)
                                THEN N'No selling price was found for Item ' + x.ItemCode + N', Unit ' + x.UnitTypeName + N', and the selected Price List.'
                           WHEN x.ManualPrice IS NOT NULL AND x.ManualPrice < 0 THEN N'Unit Price cannot be negative.' END,
               Err6 = CASE WHEN ISNULL(x.DiscountPercent, 0) < 0 OR ISNULL(x.DiscountPercent, 0) > @MaxDiscountPercent
                                THEN N'Discount % must be between 0 and ' + CAST(CAST(@MaxDiscountPercent AS DECIMAL(9,2)) AS NVARCHAR(20)) + N'.' END,
               Err7 = CASE WHEN x.ExpiryDate IS NULL AND x.RawExpiryDate IS NOT NULL THEN N'Expiry Date ''' + x.RawExpiryDate + N''' is not a valid date.' END,
               Err8 = CASE WHEN @CheckStock = 1 AND x.QtyBase > 0 AND x.WarehouseId IS NOT NULL AND x.WarehouseBranchId = @BranchId AND x.RequiredBase > ISNULL(x.OnHandBase, 0)
                                THEN N'Insufficient stock for ' + x.ItemCode + N' in ' + x.WarehouseCode + N': available ' + CAST(ISNULL(x.OnHandBase, 0) AS NVARCHAR(20))
                                     + N', required ' + CAST(x.RequiredBase AS NVARCHAR(20))
                                     + CASE WHEN x.EarlierRows IS NULL THEN N'' ELSE N' (with rows ' + x.EarlierRows + N')' END + N'.' END,
               Warn1 = CASE WHEN @PriceListId IS NOT NULL AND x.ManualPrice IS NOT NULL AND @AllowPriceOverride = 0 AND COALESCE(x.BranchPrice, x.AllBranchesPrice) IS NOT NULL
                                THEN N'Manual price ignored - system price ' + CAST(COALESCE(x.BranchPrice, x.AllBranchesPrice) AS NVARCHAR(30)) + N' used (no price override permission).' END,
               Warn2 = CASE WHEN x.ExpiryDate IS NOT NULL AND x.ExpiryDate < @Today THEN N'Expiry date is in the past.' END,
               Warn3 = CASE WHEN @PriceListId IS NOT NULL AND x.UnitName IS NULL AND x.BarcodeUnitId IS NULL AND x.ItemUnitId IS NOT NULL
                             AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits s WHERE s.ItemId = x.ItemId AND s.IsSalesUnit = 1)
                                THEN N'No sales unit is flagged for this item - the base unit was used.' END
        FROM running x
    )
    SELECT j.RowNumber,
           Status  = CASE WHEN COALESCE(j.Err1, j.Err2, j.Err3, j.Err4, j.Err5, j.Err6, j.Err7, j.Err8) IS NOT NULL THEN N'Error'
                          WHEN COALESCE(j.Warn1, j.Warn2, j.Warn3) IS NOT NULL THEN N'Warning'
                          ELSE N'Valid' END,
           Message = NULLIF(LTRIM(CONCAT(ISNULL(j.Err1 + N' ', N''), ISNULL(j.Err2 + N' ', N''), ISNULL(j.Err3 + N' ', N''), ISNULL(j.Err4 + N' ', N''),
                                         ISNULL(j.Err5 + N' ', N''), ISNULL(j.Err6 + N' ', N''), ISNULL(j.Err7 + N' ', N''), ISNULL(j.Err8 + N' ', N''),
                                         ISNULL(j.Warn1 + N' ', N''), ISNULL(j.Warn2 + N' ', N''), ISNULL(j.Warn3, N''))), N''),
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

/* ------------------------------------------------------------------ Self-test: two rows for the demo item, the second one exceeds the stock */

DECLARE @BranchId INT = (SELECT TOP (1) Id FROM masterdata.Branches WHERE IsMainBranch = 1 AND IsActive = 1);
DECLARE @WhId INT = (SELECT TOP (1) Id FROM masterdata.Warehouses WHERE BranchId = @BranchId AND IsActive = 1 ORDER BY IsMainWarehouse DESC);
DECLARE @PlId INT = (SELECT TOP (1) Id FROM masterdata.PriceLists WHERE IsActive = 1 ORDER BY Id);
DECLARE @OnHand INT = (SELECT ISNULL(inventory.fn_StockOnHand(i.Id, @WhId), 0) FROM inventory.Items i WHERE i.ItemCode = N'TVS-AP160');

IF @BranchId IS NOT NULL AND @WhId IS NOT NULL AND @PlId IS NOT NULL
BEGIN
    DECLARE @t sales.tvp_InvoiceImportRow;
    INSERT INTO @t (RowNumber, ItemRef, UnitName, WarehouseRef, Quantity, UnitPrice, DiscountPercent, ExpiryDate, Notes)
    VALUES (2, N'TVS-AP160', NULL, NULL, 1, NULL, 0, NULL, N'within stock when on-hand >= 1'),
           (3, N'TVS-AP160', NULL, NULL, @OnHand + 1, NULL, 0, NULL, N'row 2 + this row exceed the stock');

    EXEC sales.usp_InvoiceImport_Validate @BranchId = @BranchId, @DefaultWarehouseId = @WhId, @PriceListId = @PlId,
         @AllowPriceOverride = 1, @MaxDiscountPercent = 50, @Rows = @t, @CheckStock = 1;
END
GO

PRINT 'Sales - Excel import validation now checks stock (@CheckStock = 1).';
GO
