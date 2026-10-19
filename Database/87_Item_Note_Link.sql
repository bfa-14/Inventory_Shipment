SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 87: ITEMS - A NOTE AND A LINK ON THE ITEM

   Item Definition gets two free fields: a NOTE (several lines of text, for whatever the team needs to remember about
   the item) and a LINK (a web address, typically the maker's product page, opened from the page with "Open link").

     1. inventory.Items: two new nullable columns, Note NVARCHAR(2000) and Link NVARCHAR(500).
     2. inventory.usp_Item_Get: returns Note and Link. Re-created from its current body (script 61) with only that change.
     3. NEW inventory.usp_Item_SetNotes (@Id, @Note, @Link, @UserId): writes both, the way usp_Item_SetPurchasing writes
        the purchasing fields - the API calls it after the item is created or updated. An empty value is stored as NULL.
        The link must be an absolute web address: http:// or https://, a host, no spaces, at most 500 characters
        (56000 "The link must be a web address starting with http:// or https://, without spaces."). The API checks
        the same rule first; this is the last guard.

   Not changed: usp_Item_Create / usp_Item_Update / usp_Item_SetPurchasing, the search, the lookups. No new permission,
   type or error number (56000 is the item validation number). Additive and idempotent.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

/* ================================================================== 1. Columns */

IF COL_LENGTH(N'inventory.Items', N'Note') IS NULL
    ALTER TABLE inventory.Items ADD Note NVARCHAR(2000) NULL;
GO

IF COL_LENGTH(N'inventory.Items', N'Link') IS NULL
    ALTER TABLE inventory.Items ADD Link NVARCHAR(500) NULL;
GO

/* ================================================================== 2. usp_Item_Get (+ Note, Link) */

CREATE OR ALTER PROCEDURE inventory.usp_Item_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName, i.Description,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           OnHand = inventory.fn_StockOnHand(i.Id, NULL),
           FobCost = CAST(i.FobCost AS DECIMAL(18,2)),
           LastCost = CAST(i.LastCost AS DECIMAL(18,2)),
           AverageCost = CAST(i.AverageCost AS DECIMAL(18,2)),
           InventoryValue = CAST(inventory.fn_StockOnHand(i.Id, NULL) * i.AverageCost AS DECIMAL(18,2)),
           LastPurchaseCost = CAST(i.FobCost AS DECIMAL(18,2)),      -- kept for the current API mapping (= FOB)
           i.DefaultSupplierId, ds.PartyCode AS DefaultSupplierCode, ds.PartyName AS DefaultSupplierName, i.LeadTimeDays,
           PcPerContainer = cnt.PackingFormula,      -- from the item's Container unit
           PcPerContainerFromUnit = CAST(CASE WHEN cnt.PackingFormula IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           i.WeightKg, i.VolumeCbm, i.OilQtyPerUnit,
           i.LastSupplierId, ls.PartyName AS LastSupplierName, i.LastPurchaseAtUtc,
           i.Note, i.Link,                           -- (87)
           i.CreatedAtUtc, i.CreatedBy, cu.FullName AS CreatedByName,
           i.UpdatedAtUtc, i.UpdatedBy, uu.FullName AS UpdatedByName, i.RowVersion
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b       ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w   ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN masterdata.Parties ds     ON ds.Id = i.DefaultSupplierId
    LEFT  JOIN masterdata.Parties ls     ON ls.Id = i.LastSupplierId
    LEFT  JOIN security.Users cu ON cu.Id = i.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = i.UpdatedBy
    OUTER APPLY
    (
        SELECT TOP (1) u.PackingFormula
        FROM inventory.ItemUnits u INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
        WHERE u.ItemId = i.Id AND t.IsContainer = 1
    ) cnt
    WHERE i.Id = @Id;

    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit, IsContainerUnit = ut.IsContainer,
           u.LengthCm, u.WidthCm, u.HeightCm, u.WeightKg, u.RowVersion
    FROM inventory.ItemUnits u
    INNER JOIN masterdata.UnitTypes ut ON ut.Id = u.UnitTypeId
    WHERE u.ItemId = @Id
    ORDER BY u.IsBaseUnit DESC, u.PackingFormula, ut.UnitTypeName;

    SELECT fl.Id, fl.ItemId, fl.FileName, fl.ContentType, fl.SizeBytes, fl.IsItemImage, fl.CreatedAtUtc
    FROM inventory.ItemFiles fl
    WHERE fl.ItemId = @Id
    ORDER BY fl.IsItemImage DESC, fl.CreatedAtUtc DESC;
END
GO

/* ================================================================== 3. usp_Item_SetNotes */

CREATE OR ALTER PROCEDURE inventory.usp_Item_SetNotes
    @Id     INT,
    @Note   NVARCHAR(2000) = NULL,
    @Link   NVARCHAR(500)  = NULL,
    @UserId INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id) THROW 56000, 'Item not found.', 1;

    -- Blank is "no note" / "no link".
    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');
    SET @Link = NULLIF(LTRIM(RTRIM(@Link)), N'');

    /* THE LINK IS OPENED IN A NEW TAB, so only a real web address is kept: http:// or https://, something after it,
       no spaces. Anything else (javascript:, a file path, a typo) is refused rather than stored. */
    IF @Link IS NOT NULL
       AND (NOT (@Link LIKE N'http://_%' OR @Link LIKE N'https://_%')
            OR @Link LIKE N'% %' OR @Link LIKE N'%' + CHAR(9) + N'%' OR @Link LIKE N'%' + CHAR(10) + N'%' OR @Link LIKE N'%' + CHAR(13) + N'%')
        THROW 56000, 'The link must be a web address starting with http:// or https://, without spaces.', 1;

    UPDATE inventory.Items
    SET Note = @Note, Link = @Link,
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

/* ================================================================== 4. Check */

SELECT Items = COUNT(*), WithNote = COUNT(Note), WithLink = COUNT(Link) FROM inventory.Items;

PRINT 'Script 87 applied: items have a Note and a Link (inventory.usp_Item_Get, inventory.usp_Item_SetNotes).';
GO
