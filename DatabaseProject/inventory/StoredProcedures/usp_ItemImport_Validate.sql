
/* ------------------------------------------------------------------ 3. Validate */

CREATE   PROCEDURE inventory.usp_ItemImport_Validate
    @Rows inventory.tvp_ItemImportRow READONLY
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH r AS
    (
        SELECT RowNumber,
               ItemCode     = NULLIF(LTRIM(RTRIM(ItemCode)), N''),
               ItemName     = NULLIF(LTRIM(RTRIM(ItemName)), N''),
               BrandRef     = NULLIF(LTRIM(RTRIM(BrandRef)), N''),
               Model        = NULLIF(LTRIM(RTRIM(Model)), N''),
               FamilyRef    = NULLIF(LTRIM(RTRIM(FamilyRef)), N''),
               Country      = NULLIF(UPPER(LTRIM(RTRIM(Country))), N''),
               WarehouseRef = NULLIF(LTRIM(RTRIM(WarehouseRef)), N''),
               Description  = NULLIF(LTRIM(RTRIM(Description)), N''),
               WarrantyMonths, RawWarranty, MinQuantity, RawMin, MaxQuantity, RawMax,
               BivacText    = NULLIF(UPPER(LTRIM(RTRIM(BivacText))), N''),
               BaseUnitName = NULLIF(LTRIM(RTRIM(BaseUnitName)), N''),
               BaseSku      = NULLIF(LTRIM(RTRIM(BaseSku)), N''),
               BaseBarcode  = NULLIF(LTRIM(RTRIM(BaseBarcode)), N''),
               Unit2Name    = NULLIF(LTRIM(RTRIM(Unit2Name)), N''),
               Unit2Formula, RawUnit2Formula,
               Unit2Sku     = NULLIF(LTRIM(RTRIM(Unit2Sku)), N''),
               Unit2Barcode = NULLIF(LTRIM(RTRIM(Unit2Barcode)), N'')
        FROM @Rows
    ),
    resolved AS
    (
        SELECT r.*,
               b.Id  AS BrandId,        b.BrandName,       b.IsActive AS BrandActive,
               f.Id  AS ItemFamilyId,   f.FamilyName,      f.IsActive AS FamilyActive,
               w.Id  AS WarehouseId,    w.WarehouseName,   w.IsActive AS WarehouseActive,
               bu.Id AS BaseUnitTypeId, bu.IsActive AS BaseUnitActive,
               u2.Id AS Unit2TypeId,    u2.IsActive AS Unit2Active,
               IsBivac = CASE WHEN r.BivacText IN (N'YES', N'Y', N'TRUE', N'1', N'OUI') THEN CAST(1 AS BIT)
                              WHEN r.BivacText IS NULL OR r.BivacText IN (N'NO', N'N', N'FALSE', N'0', N'NON') THEN CAST(0 AS BIT) END,
               CodeDupInFile = (SELECT COUNT(*) FROM r r2 WHERE r2.ItemCode = r.ItemCode) - 1,
               BaseBarcodeDupInFile = CASE WHEN r.BaseBarcode IS NULL THEN 0 ELSE
                    (SELECT COUNT(*) FROM r r2 WHERE r2.RowNumber <> r.RowNumber AND (r2.BaseBarcode = r.BaseBarcode OR r2.Unit2Barcode = r.BaseBarcode)) END,
               Unit2BarcodeDupInFile = CASE WHEN r.Unit2Barcode IS NULL THEN 0 ELSE
                    (SELECT COUNT(*) FROM r r2 WHERE r2.RowNumber <> r.RowNumber AND (r2.BaseBarcode = r.Unit2Barcode OR r2.Unit2Barcode = r.Unit2Barcode)) END
        FROM r
        OUTER APPLY (SELECT TOP (1) Id, BrandName, IsActive FROM masterdata.Brands
                     WHERE BrandCode = r.BrandRef OR BrandName = r.BrandRef
                     ORDER BY CASE WHEN BrandCode = r.BrandRef THEN 0 ELSE 1 END) b
        OUTER APPLY (SELECT TOP (1) Id, FamilyName, IsActive FROM masterdata.ItemFamilies
                     WHERE FamilyCode = r.FamilyRef OR FamilyName = r.FamilyRef
                     ORDER BY CASE WHEN FamilyCode = r.FamilyRef THEN 0 ELSE 1 END) f
        OUTER APPLY (SELECT TOP (1) Id, WarehouseName, IsActive FROM masterdata.Warehouses
                     WHERE WarehouseCode = r.WarehouseRef OR WarehouseName = r.WarehouseRef
                     ORDER BY CASE WHEN WarehouseCode = r.WarehouseRef THEN 0 ELSE 1 END) w
        OUTER APPLY (SELECT TOP (1) Id, IsActive FROM masterdata.UnitTypes WHERE UnitTypeName = r.BaseUnitName) bu
        OUTER APPLY (SELECT TOP (1) Id, IsActive FROM masterdata.UnitTypes WHERE UnitTypeName = r.Unit2Name) u2
    ),
    judged AS
    (
        SELECT x.*,
               E1 = CASE WHEN x.ItemCode IS NULL THEN N'Item Code is required.'
                         WHEN LEN(x.ItemCode) > 30 THEN N'Item Code is longer than 30 characters.'
                         WHEN EXISTS (SELECT 1 FROM inventory.Items i WHERE i.ItemCode = x.ItemCode) THEN N'Item Code ' + x.ItemCode + N' already exists.'
                         WHEN x.CodeDupInFile > 0 THEN N'Item Code ' + x.ItemCode + N' appears more than once in the file.' END,
               E2 = CASE WHEN x.ItemName IS NULL THEN N'Item Name is required.' END,
               E3 = CASE WHEN x.BrandRef IS NULL THEN N'Brand is required.'
                         WHEN x.BrandId IS NULL THEN N'Brand ''' + x.BrandRef + N''' does not exist.'
                         WHEN x.BrandActive = 0 THEN N'Brand ''' + x.BrandRef + N''' is inactive.' END,
               E4 = CASE WHEN x.FamilyRef IS NULL THEN N'Family is required.'
                         WHEN x.ItemFamilyId IS NULL THEN N'Family ''' + x.FamilyRef + N''' does not exist.'
                         WHEN x.FamilyActive = 0 THEN N'Family ''' + x.FamilyRef + N''' is inactive.' END,
               E5 = CASE WHEN x.Country IS NULL THEN N'Country is required (2-letter ISO code).'
                         WHEN LEN(x.Country) <> 2 OR x.Country LIKE N'%[^A-Z]%' THEN N'Country ''' + x.Country + N''' must be a 2-letter ISO code.' END,
               E6 = CASE WHEN x.WarehouseRef IS NULL THEN N'Default Warehouse is required.'
                         WHEN x.WarehouseId IS NULL THEN N'Warehouse ''' + x.WarehouseRef + N''' does not exist.'
                         WHEN x.WarehouseActive = 0 THEN N'Warehouse ''' + x.WarehouseRef + N''' is inactive.' END,
               E7 = CASE WHEN x.RawWarranty IS NOT NULL AND x.WarrantyMonths IS NULL THEN N'Warranty ''' + x.RawWarranty + N''' is not a whole number.'
                         WHEN x.WarrantyMonths < 0 THEN N'Warranty cannot be negative.'
                         WHEN x.RawMin IS NOT NULL AND x.MinQuantity IS NULL THEN N'Min Qty ''' + x.RawMin + N''' is not a whole number.'
                         WHEN x.RawMax IS NOT NULL AND x.MaxQuantity IS NULL THEN N'Max Qty ''' + x.RawMax + N''' is not a whole number.'
                         WHEN ISNULL(x.MinQuantity, 0) < 0 OR x.MaxQuantity < 0 THEN N'Quantities cannot be negative.'
                         WHEN x.MaxQuantity IS NOT NULL AND ISNULL(x.MinQuantity, 0) > x.MaxQuantity THEN N'Min Qty cannot exceed Max Qty.' END,
               E8 = CASE WHEN x.IsBivac IS NULL THEN N'BIVAC must be Yes or No.' END,
               E9 = CASE WHEN x.BaseUnitName IS NULL THEN N'Base Unit is required (e.g. PC).'
                         WHEN x.BaseUnitTypeId IS NULL THEN N'Unit type ''' + x.BaseUnitName + N''' does not exist (Master Data > Unit Types).'
                         WHEN x.BaseUnitActive = 0 THEN N'Unit type ''' + x.BaseUnitName + N''' is inactive.'
                         WHEN x.BaseSku IS NULL THEN N'Base SKU is required.'
                         WHEN x.BaseBarcode IS NOT NULL AND EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.Barcode = x.BaseBarcode) THEN N'Barcode ' + x.BaseBarcode + N' is already used by another item.'
                         WHEN x.BaseBarcodeDupInFile > 0 THEN N'Barcode ' + x.BaseBarcode + N' appears more than once in the file.' END,
               E10 = CASE WHEN x.Unit2Name IS NULL AND (x.Unit2Sku IS NOT NULL OR x.Unit2Formula IS NOT NULL OR x.RawUnit2Formula IS NOT NULL OR x.Unit2Barcode IS NOT NULL) THEN N'Unit 2 name is missing.'
                          WHEN x.Unit2Name IS NULL THEN NULL
                          WHEN x.Unit2TypeId IS NULL THEN N'Unit type ''' + x.Unit2Name + N''' does not exist.'
                          WHEN x.Unit2Active = 0 THEN N'Unit type ''' + x.Unit2Name + N''' is inactive.'
                          WHEN x.Unit2TypeId = x.BaseUnitTypeId THEN N'Unit 2 must differ from the Base Unit.'
                          WHEN x.RawUnit2Formula IS NOT NULL AND x.Unit2Formula IS NULL THEN N'Unit 2 Formula ''' + x.RawUnit2Formula + N''' is not a whole number.'
                          WHEN ISNULL(x.Unit2Formula, 0) < 2 THEN N'Unit 2 Formula must be a whole number of at least 2 (base units per Unit 2).'
                          WHEN x.Unit2Sku IS NULL THEN N'Unit 2 SKU is required.'
                          WHEN x.Unit2Sku = x.BaseSku THEN N'Unit 2 SKU must differ from the Base SKU.'
                          WHEN x.Unit2Barcode IS NOT NULL AND x.Unit2Barcode = x.BaseBarcode THEN N'Unit 2 Barcode must differ from the Base Barcode.'
                          WHEN x.Unit2Barcode IS NOT NULL AND EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.Barcode = x.Unit2Barcode) THEN N'Barcode ' + x.Unit2Barcode + N' is already used by another item.'
                          WHEN x.Unit2BarcodeDupInFile > 0 THEN N'Barcode ' + x.Unit2Barcode + N' appears more than once in the file.' END,
               W1 = CASE WHEN x.BaseBarcode IS NULL THEN N'No barcode - the item cannot be scanned.' END
        FROM resolved x
    )
    SELECT j.RowNumber,
           Status  = CASE WHEN COALESCE(j.E1, j.E2, j.E3, j.E4, j.E5, j.E6, j.E7, j.E8, j.E9, j.E10) IS NOT NULL THEN N'Error'
                          WHEN j.W1 IS NOT NULL THEN N'Warning'
                          ELSE N'Valid' END,
           Message = NULLIF(RTRIM(CONCAT(ISNULL(j.E1 + N' ', N''), ISNULL(j.E2 + N' ', N''), ISNULL(j.E3 + N' ', N''), ISNULL(j.E4 + N' ', N''),
                                         ISNULL(j.E5 + N' ', N''), ISNULL(j.E6 + N' ', N''), ISNULL(j.E7 + N' ', N''), ISNULL(j.E8 + N' ', N''),
                                         ISNULL(j.E9 + N' ', N''), ISNULL(j.E10 + N' ', N''), ISNULL(j.W1, N''))), N''),
           j.ItemCode, j.ItemName, j.BrandId, j.BrandName, j.Model, j.ItemFamilyId, j.FamilyName, j.Country,
           j.WarehouseId, j.WarehouseName, j.Description, j.WarrantyMonths,
           MinQuantity = ISNULL(j.MinQuantity, 0), j.MaxQuantity, j.IsBivac,
           j.BaseUnitTypeId, j.BaseUnitName, j.BaseSku, j.BaseBarcode,
           j.Unit2TypeId, j.Unit2Name, j.Unit2Formula, j.Unit2Sku, j.Unit2Barcode
    FROM judged j
    ORDER BY j.RowNumber;
END

GO

