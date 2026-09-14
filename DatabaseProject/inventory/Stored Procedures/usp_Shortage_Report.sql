/* ================================================================== 10. Shortages report */

CREATE   PROCEDURE inventory.usp_Shortage_Report
    @BranchId       INT           = NULL,
    @WarehouseId    INT           = NULL,
    @ItemFamilyId   INT           = NULL,
    @BrandId        INT           = NULL,
    @SupplierId     INT           = NULL,     -- default supplier (else last supplier)
    @Search         NVARCHAR(200) = NULL,     -- item code / name
    @OnlyShortages  BIT           = 1,        -- 1 = rows where Available < Min; 0 = every evaluated item + warehouse
    @DaysForAverage INT           = 30
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @DaysForAverage IS NULL OR @DaysForAverage < 1 SET @DaysForAverage = 30;
    DECLARE @Since DATETIME2(3) = DATEADD(DAY, -@DaysForAverage, SYSUTCDATETIME());

    ;WITH pairs AS
    (
        SELECT i.Id AS ItemId, i.DefaultWarehouseId AS WarehouseId FROM inventory.Items i WHERE i.IsActive = 1
        UNION
        SELECT m.ItemId, m.WarehouseId FROM inventory.StockMovements m INNER JOIN inventory.Items i ON i.Id = m.ItemId WHERE i.IsActive = 1
    ),
    base AS
    (
        SELECT p.ItemId, p.WarehouseId,
               OnHandBase   = inventory.fn_StockOnHand(p.ItemId, p.WarehouseId),
               IncomingBase = ISNULL((SELECT SUM(l.QuantityBase - l.ReceivedQuantityBase)
                                      FROM purchase.PurchaseDocumentLines l
                                      INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
                                      INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                                      WHERE dt.Code = N'PO' AND d.Status = 2 AND l.ItemId = p.ItemId AND l.WarehouseId = p.WarehouseId
                                        AND l.QuantityBase > l.ReceivedQuantityBase), 0),
               SoldBase     = ISNULL((SELECT SUM(-m.QuantityBase) FROM inventory.StockMovements m
                                      WHERE m.ItemId = p.ItemId AND m.WarehouseId = p.WarehouseId AND m.DocumentFamily = N'Sales' AND m.MovementDate >= @Since), 0)
        FROM pairs p
    )
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.ItemFamilyId, f.FamilyName, i.IsBivac,
           w.Id AS WarehouseId, w.WarehouseCode, w.WarehouseName, w.BranchId, br.BranchName,
           x.OnHandBase, x.IncomingBase, AvailableBase = x.OnHandBase + x.IncomingBase,
           i.MinQuantity, i.MaxQuantity,
           ShortageBase  = CASE WHEN x.OnHandBase + x.IncomingBase < i.MinQuantity THEN i.MinQuantity - (x.OnHandBase + x.IncomingBase) ELSE 0 END,
           SuggestedBase = CASE WHEN x.OnHandBase + x.IncomingBase < i.MinQuantity THEN ISNULL(i.MaxQuantity, i.MinQuantity) - (x.OnHandBase + x.IncomingBase) ELSE 0 END,
           PurchaseItemUnitId = pu.Id, PurchaseUnitName = put.UnitTypeName, PurchasePackingFormula = pu.PackingFormula,
           SuggestedQty  = CASE WHEN x.OnHandBase + x.IncomingBase < i.MinQuantity
                                THEN CEILING(CAST(ISNULL(i.MaxQuantity, i.MinQuantity) - (x.OnHandBase + x.IncomingBase) AS DECIMAL(18,4)) / pu.PackingFormula) ELSE 0 END,
           AvgDailySalesBase = CAST(x.SoldBase AS DECIMAL(18,2)) / @DaysForAverage,
           DaysOfCover = CASE WHEN x.SoldBase > 0 THEN CAST(x.OnHandBase AS DECIMAL(18,2)) * @DaysForAverage / x.SoldBase END,
           SupplierId = COALESCE(i.DefaultSupplierId, i.LastSupplierId),
           SupplierName = COALESCE(ds.PartyName, ls.PartyName),
           SupplierIsDefault = CASE WHEN i.DefaultSupplierId IS NOT NULL THEN 1 ELSE 0 END,
           i.LastCost, i.AverageCost, i.LeadTimeDays, i.LastPurchaseAtUtc
    FROM base x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    INNER JOIN masterdata.Brands b ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
    INNER JOIN masterdata.Branches br ON br.Id = w.BranchId
    LEFT  JOIN masterdata.Parties ds ON ds.Id = i.DefaultSupplierId
    LEFT  JOIN masterdata.Parties ls ON ls.Id = i.LastSupplierId
    OUTER APPLY (SELECT TOP (1) u.Id, u.PackingFormula, u.UnitTypeId FROM inventory.ItemUnits u WHERE u.ItemId = i.Id ORDER BY u.IsPurchaseUnit DESC, u.IsBaseUnit DESC) pu
    LEFT  JOIN masterdata.UnitTypes put ON put.Id = pu.UnitTypeId
    WHERE w.IsActive = 1
      AND (@BranchId IS NULL OR w.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR w.Id = @WarehouseId)
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@SupplierId IS NULL OR COALESCE(i.DefaultSupplierId, i.LastSupplierId) = @SupplierId)
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%')
      AND (@OnlyShortages = 0 OR x.OnHandBase + x.IncomingBase < i.MinQuantity)
    ORDER BY CASE WHEN x.OnHandBase + x.IncomingBase < i.MinQuantity THEN 0 ELSE 1 END, i.ItemCode, w.WarehouseCode;
END