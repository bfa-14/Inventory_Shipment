CREATE   PROCEDURE inventory.usp_Shortage_Calculate
    @WarehouseId     INT,
    @SupplierId      INT           = NULL,
    @LeadTimeMonths  DECIMAL(6,2)  = 6,
    @MonthsOfHistory INT           = 3,
    @ItemFamilyId    INT           = NULL,
    @BrandId         INT           = NULL,
    @Search          NVARCHAR(200) = NULL,
    @OnlyShortages   BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @LeadTimeMonths IS NULL OR @LeadTimeMonths <= 0 SET @LeadTimeMonths = 6;
    IF @MonthsOfHistory IS NULL OR @MonthsOfHistory < 1 SET @MonthsOfHistory = 3;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE Id = @WarehouseId AND IsActive = 1) THROW 66000, 'Warehouse not found or inactive.', 1;

    SELECT x.ItemId, x.ItemCode, x.ItemName, b.BrandName, f.FamilyName, x.IsBivac,
           x.CurrentInventoryBase, x.TransitBase, x.OutstandingOrderBase,
           StockPlusTransitBase   = x.CurrentInventoryBase + x.TransitBase,
           TotalExpectedStockBase = x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase,
           x.ExpectedMonthlySalesBase, x.SoldInPeriodBase, MonthsOfHistory = @MonthsOfHistory, LeadTimeMonths = @LeadTimeMonths,
           ExpectedRequirementBase = CONVERT(DECIMAL(18,2), x.ExpectedMonthlySalesBase * @LeadTimeMonths),
           ShortageBase = c.ShortageBase,
           CoverageMonths = CASE WHEN x.ExpectedMonthlySalesBase > 0
                                 THEN CONVERT(DECIMAL(9,2), (x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase) / x.ExpectedMonthlySalesBase) END,
           x.PurchaseItemUnitId, x.PurchaseUnitName, x.PurchasePackingFormula,
           SuggestedRequiredQty = CASE WHEN c.ShortageBase > 0 THEN CEILING(CAST(c.ShortageBase AS DECIMAL(18,4)) / x.PurchasePackingFormula) ELSE 0 END,
           PcPerContainer = x.ItemPcPerContainer,
           ContainerRequirement = CASE WHEN x.ItemPcPerContainer > 0 AND c.ShortageBase > 0
                                       THEN CONVERT(DECIMAL(9,2), CEILING(CAST(c.ShortageBase AS DECIMAL(18,4)) / x.PurchasePackingFormula) * x.PurchasePackingFormula * 1.0 / x.ItemPcPerContainer) END,
           x.MinQuantity, x.MaxQuantity, x.LastCost, x.AverageCost, x.LeadTimeDays,
           SupplierId = COALESCE(x.DefaultSupplierId, x.LastSupplierId), SupplierName = COALESCE(ds.PartyName, ls.PartyName),
           SupplierIsDefault = CASE WHEN x.DefaultSupplierId IS NOT NULL THEN 1 ELSE 0 END
    FROM inventory.fn_Shortage_Live(@WarehouseId, @MonthsOfHistory) x
    CROSS APPLY (SELECT ShortageBase = CASE WHEN x.ExpectedMonthlySalesBase * @LeadTimeMonths - (x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase) > 0
                                            THEN CONVERT(INT, CEILING(x.ExpectedMonthlySalesBase * @LeadTimeMonths - (x.CurrentInventoryBase + x.TransitBase + x.OutstandingOrderBase))) ELSE 0 END) c
    INNER JOIN masterdata.Brands b ON b.Id = x.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = x.ItemFamilyId
    LEFT  JOIN masterdata.Parties ds ON ds.Id = x.DefaultSupplierId
    LEFT  JOIN masterdata.Parties ls ON ls.Id = x.LastSupplierId
    WHERE x.PurchaseItemUnitId IS NOT NULL
      AND (@SupplierId IS NULL OR COALESCE(x.DefaultSupplierId, x.LastSupplierId) = @SupplierId)
      AND (@ItemFamilyId IS NULL OR x.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BrandId IS NULL OR x.BrandId = @BrandId)
      AND (@Search IS NULL OR x.ItemCode LIKE N'%' + @Search + N'%' OR x.ItemName LIKE N'%' + @Search + N'%')
      AND (@OnlyShortages = 0 OR c.ShortageBase > 0)
    ORDER BY CASE WHEN c.ShortageBase > 0 THEN 0 ELSE 1 END, c.ShortageBase DESC, x.ItemCode;
END

GO

