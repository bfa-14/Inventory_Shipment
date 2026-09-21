/* =====================================================================================
   Inventory_Shipment - 23: ITEM COSTING (FOB -> landed -> moving average -> frozen COGS -> gross profit)

   Rules implemented (all costs per BASE unit in the base currency):
     FOB cost            = line total after discount / base quantity / exchange rate (purchase invoice line)
     Landed cost         = FOB + allocated purchase charges per base unit (freight, customs, BIVAC... configurable
                           charge types; allocation by Value | Quantity | Weight | Volume | Manual; amounts in any
                           currency converted with the document-date rate; rounding remainder on the largest line)
     Item.FobCost        = FOB of the latest posted purchase invoice
     Item.LastCost       = LANDED cost of the latest posted purchase invoice (Inventory In does not touch it)
     Item.AverageCost    = moving weighted average, recalculated only when a posting ADDS stock:
                           new avg = (on-hand x old avg + received qty x landed cost) / (on-hand + received qty)
     Inventory value     = on-hand x average cost (views vw_InventoryValuation / ...ByWarehouse)
     Sales invoice       = COGS frozen per line at posting (average cost) + FOB / last cost snapshots, net sales,
                           gross profit and gross profit % (on net sales) in the base currency
     Sales return        = restores stock at the ORIGINAL invoice COGS (SINV -> SRET conversion procedure)
     Purchase return     = removes stock at the original invoice landed cost
     Landed Cost Adjustment (LCA) = charges arriving after receipt, allocated over the invoice lines and split:
                           still-in-stock quantity -> inventory value (average recalculated),
                           already-sold quantity   -> COGS adjustment (period P&L, inventory.CostAdjustments)
     Cancelling a posted receipt / LCA rebuilds the item costs by replaying the ledger (usp_Item_RebuildCosts)

   Objects: inventory.Items + FobCost, WeightKg, VolumeCbm; inventory.tvp_ItemReceipt re-created (+ FobCostBase);
            inventory.usp_Item_ApplyReceipts (+ @UpdateLastCost), usp_Item_RebuildCosts, usp_Item_Get / _Search /
            _SetPurchasing re-created; inventory.CostAdjustments; views vw_InventoryValuation(+ByWarehouse)
            purchase.ChargeTypes (+ usp_ChargeType_List / _Save), purchase.PurchaseCharges,
            purchase.PurchaseChargeAllocations, tvp_PurchaseCharge, tvp_ManualAllocation,
            usp_PurchaseDocument_SetCharges, usp_PurchaseCharges_Allocate;
            purchase.PurchaseDocumentLines + FobCostBase, AllocatedChargesBase; PurchaseDocuments + TotalChargesBase;
            purchase.LandedCostAdjustments / LandedCostAdjustmentLines, document type LCA,
            usp_LandedCostAdjustment_Search / _Get / _Save / _Post / _Cancel / _Delete;
            purchase.usp_PurchaseDocument_Save / _Post / _Cancel / _Delete / _Get re-created;
            sales.SalesDocumentLines + FobCostAtSale, LastCostAtSale, NetSalesBase, CogsBase, GrossProfitBase,
            GrossProfitPct, ReturnedQuantityBase; SalesDocuments + TotalGrossProfitBase;
            sales.usp_SalesDocument_Save / _Post / _Cancel / _Get re-created, usp_SalesDocument_CreateFromSource
            (SINV -> SRET), sales.usp_SalesProfit_Report; inventory.usp_StockDocument_Post re-created.
   Errors: 65012 CHARGE_ALLOCATION (purchase charges), 67xxx landed cost adjustments (67000 validation,
           67004 concurrency, 67005 not a draft, 67006 not found, 67010 invalid status, 67011 source invoice problem)
   Permissions: purchase.landedcosts.view/create/post/cancel/delete (1180-1220), purchase.chargetypes.manage
                (Configuration 910), sales.profit.view (Sales 680)
   Requires 19, 21, 22. Idempotent (types are dropped/re-created only when the new column is missing).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

-- sqlcmd defaults to QUOTED_IDENTIFIER OFF; the procedures below insert into tables with PERSISTED
-- computed columns (Sales/Purchase document lines), which need it ON in the procedure that writes to them
-- (the setting is captured when the procedure is created).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID(N'purchase.PurchaseDocumentLines', N'U') IS NULL OR COL_LENGTH(N'purchase.PurchaseDocumentLines', N'ShippedQuantityBase') IS NULL
BEGIN
    RAISERROR ('Run scripts 19, 21 and 22 before this script.', 16, 1);
    RETURN;
END
GO

/* ================================================================== 1. Items: FOB cost, weight, volume */

IF COL_LENGTH(N'inventory.Items', N'FobCost') IS NULL
BEGIN
    ALTER TABLE inventory.Items ADD
        FobCost   DECIMAL(18,6) NULL,   -- latest purchase FOB cost per base unit, base currency
        WeightKg  DECIMAL(18,3) NULL,   -- per base unit (charge allocation by weight)
        VolumeCbm DECIMAL(18,4) NULL,   -- per base unit (charge allocation by volume)
        CONSTRAINT CK_Items_WeightKg CHECK (WeightKg IS NULL OR WeightKg >= 0),
        CONSTRAINT CK_Items_VolumeCbm CHECK (VolumeCbm IS NULL OR VolumeCbm >= 0);
    PRINT 'Items: added FobCost, WeightKg, VolumeCbm';
END
GO

-- Backfill FOB from the latest posted purchase invoice when the column is new.
UPDATE i SET FobCost = x.Fob
FROM inventory.Items i
CROSS APPLY (SELECT TOP (1) Fob = l.UnitCostBase
             FROM purchase.PurchaseDocumentLines l
             INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
             INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
             WHERE dt.Code = N'PINV' AND d.Status = 2 AND l.ItemId = i.Id
             ORDER BY d.PostedAtUtc DESC, l.Id DESC) x
WHERE i.FobCost IS NULL AND x.Fob IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_SetPurchasing
    @Id                INT,
    @DefaultSupplierId INT           = NULL,
    @LeadTimeDays      INT           = NULL,
    @UserId            INT           = NULL,
    @PcPerContainer    INT           = NULL,
    @WeightKg          DECIMAL(18,3) = NULL,
    @VolumeCbm         DECIMAL(18,4) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id) THROW 56000, 'Item not found.', 1;
    IF @DefaultSupplierId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @DefaultSupplierId AND IsSupplier = 1 AND IsActive = 1)
        THROW 56000, 'Default supplier not found, inactive, or not flagged as a supplier.', 1;
    IF @LeadTimeDays IS NOT NULL AND @LeadTimeDays < 0 THROW 56000, 'Lead time cannot be negative.', 1;
    IF @PcPerContainer IS NOT NULL AND @PcPerContainer <= 0 THROW 56000, 'PC per container must be greater than zero.', 1;
    IF @WeightKg IS NOT NULL AND @WeightKg < 0 THROW 56000, 'Weight cannot be negative.', 1;
    IF @VolumeCbm IS NOT NULL AND @VolumeCbm < 0 THROW 56000, 'Volume cannot be negative.', 1;

    UPDATE inventory.Items
    SET DefaultSupplierId = @DefaultSupplierId, LeadTimeDays = @LeadTimeDays, PcPerContainer = @PcPerContainer,
        WeightKg = @WeightKg, VolumeCbm = @VolumeCbm, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END
GO

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
           i.DefaultSupplierId, ds.PartyCode AS DefaultSupplierCode, ds.PartyName AS DefaultSupplierName, i.LeadTimeDays, i.PcPerContainer,
           i.WeightKg, i.VolumeCbm,
           i.LastSupplierId, ls.PartyName AS LastSupplierName, i.LastPurchaseAtUtc,
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
    WHERE i.Id = @Id;

    SELECT u.Id, u.ItemId, u.UnitTypeId, ut.UnitTypeName, u.PackingFormula, u.SkuCode, u.Barcode,
           u.IsSalesUnit, u.IsPurchaseUnit, u.IsBaseUnit, u.RowVersion
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

CREATE OR ALTER PROCEDURE inventory.usp_Item_Search
    @Search             NVARCHAR(200) = NULL,
    @ItemFamilyId       INT           = NULL,
    @BrandId            INT           = NULL,
    @DefaultWarehouseId INT           = NULL,
    @IsActive           BIT           = NULL,
    @IsBivac            BIT           = NULL,
    @SortColumn         NVARCHAR(30)  = N'ItemCode',
    @SortDirection      NVARCHAR(4)   = N'ASC',
    @PageNumber         INT           = 1,
    @PageSize           INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ItemCode', N'ItemName', N'BrandName', N'FamilyName', N'WarehouseName', N'IsActive', N'CreatedAtUtc', N'OnHand')
        SET @SortColumn = N'ItemCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT i.Id, i.ItemCode, i.ItemName, i.BrandId, b.BrandName, i.Model,
           i.ItemFamilyId, f.FamilyCode, f.FamilyName, i.CountryOfOrigin,
           i.DefaultWarehouseId, w.WarehouseCode, w.WarehouseName,
           i.WarrantyMonths, i.MinQuantity, i.MaxQuantity, i.IsBivac, i.IsActive,
           bu.SkuCode AS BaseUnitSku, ut.UnitTypeName AS BaseUnitName,
           OnHand = inventory.fn_StockOnHand(i.Id, NULL),
           FobCost = CAST(i.FobCost AS DECIMAL(18,2)), LastCost = CAST(i.LastCost AS DECIMAL(18,2)),
           AverageCost = CAST(i.AverageCost AS DECIMAL(18,2)),
           InventoryValue = CAST(inventory.fn_StockOnHand(i.Id, NULL) * i.AverageCost AS DECIMAL(18,2)),
           i.DefaultSupplierId, ds.PartyName AS DefaultSupplierName,
           i.CreatedAtUtc, i.CreatedBy, i.UpdatedAtUtc, i.UpdatedBy, i.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM inventory.Items i
    INNER JOIN masterdata.Brands b        ON b.Id = i.BrandId
    INNER JOIN masterdata.ItemFamilies f  ON f.Id = i.ItemFamilyId
    INNER JOIN masterdata.Warehouses w    ON w.Id = i.DefaultWarehouseId
    LEFT  JOIN inventory.ItemUnits bu     ON bu.ItemId = i.Id AND bu.IsBaseUnit = 1
    LEFT  JOIN masterdata.UnitTypes ut    ON ut.Id = bu.UnitTypeId
    LEFT  JOIN masterdata.Parties ds      ON ds.Id = i.DefaultSupplierId
    WHERE (@Search IS NULL
           OR i.ItemCode LIKE N'%' + @Search + N'%'
           OR i.ItemName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits u
                      WHERE u.ItemId = i.Id AND (u.SkuCode LIKE N'%' + @Search + N'%' OR u.Barcode LIKE N'%' + @Search + N'%')))
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@DefaultWarehouseId IS NULL OR i.DefaultWarehouseId = @DefaultWarehouseId)
      AND (@IsActive IS NULL OR i.IsActive = @IsActive)
      AND (@IsBivac IS NULL OR i.IsBivac = @IsBivac)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName WHEN N'BrandName' THEN b.BrandName
                             WHEN N'FamilyName' THEN f.FamilyName WHEN N'WarehouseName' THEN w.WarehouseName END
        END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN
            CASE @SortColumn WHEN N'ItemCode' THEN i.ItemCode WHEN N'ItemName' THEN i.ItemName WHEN N'BrandName' THEN b.BrandName
                             WHEN N'FamilyName' THEN f.FamilyName WHEN N'WarehouseName' THEN w.WarehouseName END
        END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'OnHand' THEN inventory.fn_StockOnHand(i.Id, NULL) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'OnHand' THEN inventory.fn_StockOnHand(i.Id, NULL) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(i.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(i.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN i.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN i.CreatedAtUtc END DESC,
        i.ItemCode ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

/* ================================================================== 2. Cost adjustments ledger + valuation views */

IF OBJECT_ID(N'inventory.CostAdjustments', N'U') IS NULL
BEGIN
    CREATE TABLE inventory.CostAdjustments
    (
        Id             BIGINT IDENTITY(1,1) NOT NULL,
        AdjustmentDate DATETIME2(3)  NOT NULL,
        ItemId         INT           NOT NULL,
        WarehouseId    INT           NOT NULL,
        BranchId       INT           NOT NULL,
        Kind           NVARCHAR(10)  NOT NULL,     -- Inventory (value added to stock) | COGS (expense of already-sold quantity)
        AmountBase     DECIMAL(18,2) NOT NULL,     -- signed (negative = reversal)
        SourceKind     NVARCHAR(10)  NOT NULL,     -- LCA
        SourceId       INT           NOT NULL,
        SourceNumber   NVARCHAR(30)  NOT NULL,
        PurchaseLineId INT           NULL,
        CreatedAtUtc   DATETIME2(3)  NOT NULL CONSTRAINT DF_CostAdjustments_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy      INT           NULL,
        CONSTRAINT PK_CostAdjustments PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT CK_CostAdjustments_Kind CHECK (Kind IN (N'Inventory', N'COGS')),
        CONSTRAINT FK_CostAdjustments_Item      FOREIGN KEY (ItemId)      REFERENCES inventory.Items (Id),
        CONSTRAINT FK_CostAdjustments_Warehouse FOREIGN KEY (WarehouseId) REFERENCES masterdata.Warehouses (Id),
        CONSTRAINT FK_CostAdjustments_Branch    FOREIGN KEY (BranchId)    REFERENCES masterdata.Branches (Id)
    );
    CREATE NONCLUSTERED INDEX IX_CostAdjustments_ItemDate ON inventory.CostAdjustments (ItemId, AdjustmentDate);
    CREATE NONCLUSTERED INDEX IX_CostAdjustments_Source   ON inventory.CostAdjustments (SourceKind, SourceId);
    PRINT 'Created inventory.CostAdjustments';
END
GO

CREATE OR ALTER VIEW inventory.vw_InventoryValuation
AS
    SELECT i.Id AS ItemId, i.ItemCode, i.ItemName, i.BrandId, i.ItemFamilyId,
           OnHandBase = inventory.fn_StockOnHand(i.Id, NULL),
           i.AverageCost, i.LastCost, i.FobCost,
           InventoryValue = CAST(inventory.fn_StockOnHand(i.Id, NULL) * i.AverageCost AS DECIMAL(18,2))
    FROM inventory.Items i
    WHERE i.IsActive = 1;
GO

CREATE OR ALTER VIEW inventory.vw_InventoryValuationByWarehouse
AS
    SELECT b.ItemId, b.ItemCode, b.ItemName, b.WarehouseId, b.WarehouseCode, b.WarehouseName, b.BranchId,
           b.OnHandBase, i.AverageCost,
           InventoryValue = CAST(b.OnHandBase * i.AverageCost AS DECIMAL(18,2))
    FROM inventory.vw_StockBalance b
    INNER JOIN inventory.Items i ON i.Id = b.ItemId;
GO

/* ================================================================== 3. Receipts: moving average + FOB (type re-created) */

IF TYPE_ID(N'inventory.tvp_ItemReceipt') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.columns c INNER JOIN sys.table_types tt ON tt.type_table_object_id = c.object_id
                   WHERE tt.name = N'tvp_ItemReceipt' AND SCHEMA_NAME(tt.schema_id) = N'inventory' AND c.name = N'FobCostBase')
BEGIN
    IF OBJECT_ID(N'inventory.usp_Item_ApplyReceipts', N'P') IS NOT NULL DROP PROCEDURE inventory.usp_Item_ApplyReceipts;
    IF OBJECT_ID(N'inventory.usp_StockDocument_Post', N'P') IS NOT NULL DROP PROCEDURE inventory.usp_StockDocument_Post;
    IF OBJECT_ID(N'sales.usp_SalesDocument_Post', N'P') IS NOT NULL DROP PROCEDURE sales.usp_SalesDocument_Post;
    IF OBJECT_ID(N'purchase.usp_PurchaseDocument_Post', N'P') IS NOT NULL DROP PROCEDURE purchase.usp_PurchaseDocument_Post;
    DROP TYPE inventory.tvp_ItemReceipt;
    PRINT 'Dropped inventory.tvp_ItemReceipt (re-created with FobCostBase; the posting procedures are re-created below)';
END
GO

IF TYPE_ID(N'inventory.tvp_ItemReceipt') IS NULL
BEGIN
    CREATE TYPE inventory.tvp_ItemReceipt AS TABLE
    (
        ItemId       INT           NOT NULL,
        QuantityBase INT           NOT NULL,      -- received, base units (> 0)
        UnitCostBase DECIMAL(18,6) NOT NULL,      -- LANDED cost per base unit, base currency
        FobCostBase  DECIMAL(18,6) NULL           -- FOB per base unit (purchases only)
    );
    PRINT 'Created type inventory.tvp_ItemReceipt';
END
GO

-- Moving average. CALL BEFORE the receipt movements are inserted. @UpdateLastCost = 1 only for purchase receipts.
CREATE OR ALTER PROCEDURE inventory.usp_Item_ApplyReceipts
    @Receipts       inventory.tvp_ItemReceipt READONLY,
    @SupplierId     INT = NULL,
    @UserId         INT = NULL,
    @UpdateLastCost BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS
    (
        SELECT ItemId,
               Qty    = SUM(QuantityBase),
               Cost   = SUM(CAST(QuantityBase AS DECIMAL(18,6)) * UnitCostBase),
               FobQty = SUM(CASE WHEN FobCostBase IS NOT NULL THEN QuantityBase ELSE 0 END),
               Fob    = SUM(CASE WHEN FobCostBase IS NOT NULL THEN CAST(QuantityBase AS DECIMAL(18,6)) * FobCostBase ELSE 0 END)
        FROM @Receipts WHERE QuantityBase > 0 GROUP BY ItemId
    )
    UPDATE i
    SET AverageCost       = CASE WHEN oh.Q + a.Qty > 0 THEN (oh.Q * i.AverageCost + a.Cost) / (oh.Q + a.Qty) ELSE i.AverageCost END,
        LastCost          = CASE WHEN @UpdateLastCost = 1 THEN a.Cost / a.Qty ELSE i.LastCost END,
        FobCost           = CASE WHEN @UpdateLastCost = 1 AND a.FobQty > 0 THEN a.Fob / a.FobQty ELSE i.FobCost END,
        LastSupplierId    = CASE WHEN @UpdateLastCost = 1 THEN COALESCE(@SupplierId, i.LastSupplierId) ELSE i.LastSupplierId END,
        LastPurchaseAtUtc = CASE WHEN @UpdateLastCost = 1 AND @SupplierId IS NOT NULL THEN SYSUTCDATETIME() ELSE i.LastPurchaseAtUtc END
    FROM inventory.Items i
    INNER JOIN agg a ON a.ItemId = i.Id
    CROSS APPLY (SELECT Q = CAST(CASE WHEN inventory.fn_StockOnHand(i.Id, NULL) > 0 THEN inventory.fn_StockOnHand(i.Id, NULL) ELSE 0 END AS DECIMAL(18,6))) oh;
END
GO

-- Replays the ledger (documents without reversal) + inventory cost adjustments in date order -> exact moving average;
-- LastCost / FobCost from the latest posted purchase invoice. @ItemId NULL = every item (maintenance).
CREATE OR ALTER PROCEDURE inventory.usp_Item_RebuildCosts
    @ItemId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Events TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, ItemId INT, Qty INT, Cost DECIMAL(18,6), Amount DECIMAL(18,2));
    INSERT INTO @Events (ItemId, Qty, Cost, Amount)
    SELECT x.ItemId, x.Qty, x.Cost, x.Amount
    FROM
    (
        SELECT m.ItemId, EventDate = m.MovementDate, Src = 1, SrcId = m.Id, Qty = m.QuantityBase, Cost = m.UnitCostBase, Amount = CAST(NULL AS DECIMAL(18,2))
        FROM inventory.StockMovements m
        WHERE (@ItemId IS NULL OR m.ItemId = @ItemId)
          AND NOT EXISTS (SELECT 1 FROM inventory.StockMovements r WHERE r.DocumentFamily = m.DocumentFamily AND r.DocumentId = m.DocumentId AND r.IsReversal = 1)
        UNION ALL
        SELECT c.ItemId, c.AdjustmentDate, 2, CAST(c.Id AS INT), 0, NULL, c.AmountBase
        FROM inventory.CostAdjustments c
        WHERE c.Kind = N'Inventory' AND (@ItemId IS NULL OR c.ItemId = @ItemId)
    ) x
    ORDER BY x.ItemId, x.EventDate, x.Src, x.SrcId;

    DECLARE @Result TABLE (ItemId INT PRIMARY KEY, AverageCost DECIMAL(18,6));
    DECLARE @CurItem INT = NULL, @OnHand DECIMAL(18,6) = 0, @Avg DECIMAL(18,6) = 0;
    DECLARE @EItem INT, @EQty INT, @ECost DECIMAL(18,6), @EAmount DECIMAL(18,2);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT ItemId, Qty, Cost, Amount FROM @Events ORDER BY Seq;
    OPEN cur;
    FETCH NEXT FROM cur INTO @EItem, @EQty, @ECost, @EAmount;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @CurItem IS NULL OR @CurItem <> @EItem
        BEGIN
            IF @CurItem IS NOT NULL INSERT INTO @Result (ItemId, AverageCost) VALUES (@CurItem, @Avg);
            SELECT @CurItem = @EItem, @OnHand = 0, @Avg = 0;
        END

        IF @EAmount IS NOT NULL                                   -- inventory value adjustment (LCA)
            SET @Avg = CASE WHEN @OnHand > 0 THEN @Avg + @EAmount / @OnHand ELSE @Avg END;
        ELSE IF @EQty > 0                                         -- receipt
        BEGIN
            SET @Avg = CASE WHEN @OnHand + @EQty > 0 THEN ((CASE WHEN @OnHand > 0 THEN @OnHand ELSE 0 END) * @Avg + @EQty * ISNULL(@ECost, @Avg)) / ((CASE WHEN @OnHand > 0 THEN @OnHand ELSE 0 END) + @EQty) ELSE @Avg END;
            SET @OnHand = @OnHand + @EQty;
        END
        ELSE                                                      -- issue: average unchanged
            SET @OnHand = @OnHand + @EQty;

        FETCH NEXT FROM cur INTO @EItem, @EQty, @ECost, @EAmount;
    END
    CLOSE cur; DEALLOCATE cur;
    IF @CurItem IS NOT NULL INSERT INTO @Result (ItemId, AverageCost) VALUES (@CurItem, @Avg);

    -- Items with no remaining events (everything cancelled) fall back to 0.
    UPDATE i SET AverageCost = ISNULL(r.AverageCost, 0)
    FROM inventory.Items i
    LEFT JOIN @Result r ON r.ItemId = i.Id
    WHERE (@ItemId IS NULL OR i.Id = @ItemId);

    UPDATE i
    SET LastCost = x.Landed, FobCost = x.Fob, LastSupplierId = x.SupplierId, LastPurchaseAtUtc = x.PostedAtUtc
    FROM inventory.Items i
    OUTER APPLY (SELECT TOP (1) Landed = l.UnitCostBase, Fob = l.FobCostBase, d.SupplierId, d.PostedAtUtc
                 FROM purchase.PurchaseDocumentLines l
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
                 INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                 WHERE dt.Code = N'PINV' AND d.Status = 2 AND l.ItemId = i.Id
                 ORDER BY d.PostedAtUtc DESC, l.Id DESC) x
    WHERE (@ItemId IS NULL OR i.Id = @ItemId);
END
GO

/* ================================================================== 4. Purchase charge types (US-MD-008) */

IF OBJECT_ID(N'purchase.ChargeTypes', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.ChargeTypes
    (
        Id                  INT IDENTITY(1,1) NOT NULL,
        ChargeCode          NVARCHAR(10)  NOT NULL,
        ChargeName          NVARCHAR(100) NOT NULL,
        AllocationMethod    NVARCHAR(10)  NOT NULL,     -- Value | Quantity | Weight | Volume | Manual
        IncludeInLandedCost BIT           NOT NULL CONSTRAINT DF_ChargeTypes_Landed DEFAULT (1),
        IsRecoverableTax    BIT           NOT NULL CONSTRAINT DF_ChargeTypes_RecoverableTax DEFAULT (0),   -- recoverable VAT: never part of the item cost
        Description         NVARCHAR(500) NULL,
        IsActive            BIT           NOT NULL CONSTRAINT DF_ChargeTypes_IsActive DEFAULT (1),
        CreatedAtUtc        DATETIME2(3)  NOT NULL CONSTRAINT DF_ChargeTypes_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy           INT           NULL,
        UpdatedAtUtc        DATETIME2(3)  NULL,
        UpdatedBy           INT           NULL,
        RowVersion          ROWVERSION    NOT NULL,
        CONSTRAINT PK_ChargeTypes PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_ChargeTypes_Code UNIQUE (ChargeCode),
        CONSTRAINT UQ_ChargeTypes_Name UNIQUE (ChargeName),
        CONSTRAINT CK_ChargeTypes_Method CHECK (AllocationMethod IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual')),
        CONSTRAINT CK_ChargeTypes_TaxNotLanded CHECK (NOT (IsRecoverableTax = 1 AND IncludeInLandedCost = 1)),
        CONSTRAINT FK_ChargeTypes_CreatedBy FOREIGN KEY (CreatedBy) REFERENCES security.Users (Id),
        CONSTRAINT FK_ChargeTypes_UpdatedBy FOREIGN KEY (UpdatedBy) REFERENCES security.Users (Id)
    );
    PRINT 'Created purchase.ChargeTypes';
END
GO

MERGE purchase.ChargeTypes AS t
USING (VALUES
    (N'FRE', N'Freight',               N'Weight',   1, 0, N'Ocean / air freight charges'),
    (N'INS', N'Insurance',             N'Value',    1, 0, N'Cargo insurance'),
    (N'CUS', N'Customs',               N'Value',    1, 0, N'Customs duty and taxes'),
    (N'CLR', N'Clearing',              N'Value',    1, 0, N'Clearing agent fees'),
    (N'POR', N'Port Charges',          N'Volume',   1, 0, N'Port handling charges'),
    (N'BIV', N'BIVAC / Inspection',    N'Value',    1, 0, N'BIVAC inspection fees'),
    (N'TRP', N'Inland Transportation', N'Weight',   1, 0, N'Local transport to warehouse'),
    (N'HDL', N'Handling',              N'Quantity', 1, 0, N'Loading / unloading charges'),
    (N'ADM', N'Administration',        N'Manual',   0, 1, N'Administrative fees (not in cost)'),
    (N'OTH', N'Other Charges',         N'Manual',   1, 0, N'Other acquisition costs')
) AS s (ChargeCode, ChargeName, AllocationMethod, IncludeInLandedCost, IsRecoverableTax, Description)
ON t.ChargeCode = s.ChargeCode
WHEN NOT MATCHED BY TARGET THEN
    INSERT (ChargeCode, ChargeName, AllocationMethod, IncludeInLandedCost, IsRecoverableTax, Description)
    VALUES (s.ChargeCode, s.ChargeName, s.AllocationMethod, s.IncludeInLandedCost, s.IsRecoverableTax, s.Description);
GO

CREATE OR ALTER PROCEDURE purchase.usp_ChargeType_Search
    @Search              NVARCHAR(100) = NULL,   -- code or name (contains)
    @AllocationMethod    NVARCHAR(10)  = NULL,
    @IncludeInLandedCost BIT           = NULL,   -- "Cost impact" filter
    @IsActive            BIT           = NULL,
    @SortColumn          NVARCHAR(30)  = N'ChargeCode',
    @SortDirection       NVARCHAR(4)   = N'ASC',
    @PageNumber          INT           = 1,
    @PageSize            INT           = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ChargeCode', N'ChargeName', N'AllocationMethod', N'IsActive', N'CreatedAtUtc') SET @SortColumn = N'ChargeCode';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'ASC';
    SET @SortDirection = UPPER(@SortDirection);

    SELECT c.Id, c.ChargeCode, c.ChargeName, c.AllocationMethod, c.IncludeInLandedCost, c.IsRecoverableTax, c.Description, c.IsActive,
           UsageCount = (SELECT COUNT(*) FROM purchase.PurchaseCharges pc WHERE pc.ChargeTypeId = c.Id),
           c.CreatedAtUtc, c.UpdatedAtUtc, c.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM purchase.ChargeTypes c
    WHERE (@Search IS NULL OR c.ChargeCode LIKE N'%' + @Search + N'%' OR c.ChargeName LIKE N'%' + @Search + N'%')
      AND (@AllocationMethod IS NULL OR c.AllocationMethod = @AllocationMethod)
      AND (@IncludeInLandedCost IS NULL OR c.IncludeInLandedCost = @IncludeInLandedCost)
      AND (@IsActive IS NULL OR c.IsActive = @IsActive)
    ORDER BY
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'ChargeCode' THEN c.ChargeCode WHEN N'ChargeName' THEN c.ChargeName WHEN N'AllocationMethod' THEN c.AllocationMethod END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'ChargeCode' THEN c.ChargeCode WHEN N'ChargeName' THEN c.ChargeName WHEN N'AllocationMethod' THEN c.AllocationMethod END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'IsActive' THEN CAST(c.IsActive AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'IsActive' THEN CAST(c.IsActive AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END DESC,
        c.ChargeCode
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_ChargeType_Lookup
    @ActiveOnly BIT = 1, @IncludeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ChargeCode, ChargeName, AllocationMethod, IncludeInLandedCost, IsRecoverableTax, IsActive
    FROM purchase.ChargeTypes
    WHERE @ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId
    ORDER BY ChargeName;
END
GO

-- Create (@Id NULL) or update. Errors 68xxx: 68000 validation, 68001 duplicate code, 68002 duplicate name, 68004 concurrency, 68005 in use, 68006 not found.
CREATE OR ALTER PROCEDURE purchase.usp_ChargeType_Save
    @Id                  INT           = NULL,
    @ChargeCode          NVARCHAR(10),
    @ChargeName          NVARCHAR(100),
    @AllocationMethod    NVARCHAR(10),
    @IncludeInLandedCost BIT           = 1,
    @IsRecoverableTax    BIT           = 0,
    @Description         NVARCHAR(500) = NULL,
    @IsActive            BIT           = 1,
    @RowVersion          BINARY(8)     = NULL,
    @UserId              INT           = NULL,
    @NewId               INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @ChargeCode = UPPER(NULLIF(LTRIM(RTRIM(@ChargeCode)), N''));
    SET @ChargeName = NULLIF(LTRIM(RTRIM(@ChargeName)), N'');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    IF @ChargeCode IS NULL THROW 68000, 'Charge Code is required.', 1;
    IF @ChargeName IS NULL THROW 68000, 'Charge Name is required.', 1;
    IF @AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual') THROW 68000, 'Allocation method must be Value, Quantity, Weight, Volume or Manual.', 1;
    IF ISNULL(@IsRecoverableTax, 0) = 1 AND ISNULL(@IncludeInLandedCost, 1) = 1 THROW 68000, 'A recoverable tax cannot be included in the landed cost.', 1;
    IF EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE ChargeCode = @ChargeCode AND (@Id IS NULL OR Id <> @Id)) THROW 68001, 'This Charge Code already exists.', 1;
    IF EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE ChargeName = @ChargeName AND (@Id IS NULL OR Id <> @Id)) THROW 68002, 'This Charge Name already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO purchase.ChargeTypes (ChargeCode, ChargeName, AllocationMethod, IncludeInLandedCost, IsRecoverableTax, Description, IsActive, CreatedBy)
        VALUES (@ChargeCode, @ChargeName, @AllocationMethod, ISNULL(@IncludeInLandedCost, 1), ISNULL(@IsRecoverableTax, 0), @Description, ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id) THROW 68006, 'Charge type not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 68004, 'This charge type was modified by another user. Reload the page and try again.', 1;
        UPDATE purchase.ChargeTypes
        SET ChargeCode = @ChargeCode, ChargeName = @ChargeName, AllocationMethod = @AllocationMethod, IncludeInLandedCost = ISNULL(@IncludeInLandedCost, 1),
            IsRecoverableTax = ISNULL(@IsRecoverableTax, 0), Description = @Description, IsActive = ISNULL(@IsActive, 1),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_ChargeType_SetActive
    @Id INT, @IsActive BIT, @RowVersion BINARY(8) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id) THROW 68006, 'Charge type not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 68004, 'This charge type was modified by another user. Reload the page and try again.', 1;
    UPDATE purchase.ChargeTypes SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_ChargeType_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id) THROW 68006, 'Charge type not found.', 1;
    IF EXISTS (SELECT 1 FROM purchase.PurchaseCharges WHERE ChargeTypeId = @Id)
        THROW 68005, 'This charge type was used in transactions and cannot be deleted. Deactivate it instead.', 1;
    DELETE FROM purchase.ChargeTypes WHERE Id = @Id;
END
GO

/* ================================================================== 5. Purchase charges on invoices / adjustments + allocations */

IF COL_LENGTH(N'purchase.PurchaseDocumentLines', N'FobCostBase') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocumentLines ADD
        FobCostBase          DECIMAL(18,6) NULL,                                                       -- per base unit, base currency
        AllocatedChargesBase DECIMAL(18,2) NOT NULL CONSTRAINT DF_PurchaseDocumentLines_Charges DEFAULT (0);   -- landed charges of the line
    PRINT 'PurchaseDocumentLines: added FobCostBase, AllocatedChargesBase';
END
GO

IF COL_LENGTH(N'purchase.PurchaseDocuments', N'TotalChargesBase') IS NULL
BEGIN
    ALTER TABLE purchase.PurchaseDocuments ADD
        TotalChargesBase    DECIMAL(18,2) NOT NULL CONSTRAINT DF_PurchaseDocuments_Charges DEFAULT (0),      -- landed charges (invoice + adjustments)
        TotalLandedCostBase DECIMAL(18,2) NOT NULL CONSTRAINT DF_PurchaseDocuments_Landed DEFAULT (0);       -- TotalAmountBase + TotalChargesBase
    PRINT 'PurchaseDocuments: added TotalChargesBase, TotalLandedCostBase';
END
GO

-- Existing posted invoices: FOB = the landed cost known so far (no charges existed).
UPDATE l SET FobCostBase = l.UnitCostBase
FROM purchase.PurchaseDocumentLines l
INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
WHERE l.FobCostBase IS NULL AND d.Status IN (2, 3, 4) AND l.UnitCostBase IS NOT NULL;
UPDATE purchase.PurchaseDocuments SET TotalLandedCostBase = TotalAmountBase WHERE TotalLandedCostBase = 0 AND TotalAmountBase <> 0;
GO

IF OBJECT_ID(N'purchase.PurchaseCharges', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseCharges
    (
        Id                        INT IDENTITY(1,1) NOT NULL,
        DocumentKind              NVARCHAR(10)  NOT NULL,     -- PINV (charges known on the invoice) | LCA (landed cost adjustment)
        DocumentId                INT           NOT NULL,
        LineNumber                INT           NOT NULL,
        ChargeTypeId              INT           NOT NULL,
        Description               NVARCHAR(200) NULL,
        ProviderPartyId           INT           NULL,         -- who bills the charge (forwarder, customs agent...)
        Reference                 NVARCHAR(100) NULL,         -- provider's invoice / receipt number
        CurrencyId                INT           NOT NULL,
        RateType                  TINYINT       NOT NULL CONSTRAINT DF_PurchaseCharges_RateType DEFAULT (1),
        ExchangeRate              DECIMAL(18,6) NOT NULL CONSTRAINT DF_PurchaseCharges_Rate DEFAULT (1),
        Amount                    DECIMAL(18,2) NOT NULL,
        AmountBase                DECIMAL(18,2) NOT NULL,
        AllocationMethod          NVARCHAR(10)  NOT NULL,     -- copied from the type, overridable per charge
        IncludeInLandedCost       BIT           NOT NULL,     -- copied from the type at save time
        IncludedInSupplierInvoice BIT           NOT NULL CONSTRAINT DF_PurchaseCharges_InSupplierInvoice DEFAULT (0),
        Notes                     NVARCHAR(300) NULL,
        CreatedAtUtc              DATETIME2(3)  NOT NULL CONSTRAINT DF_PurchaseCharges_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy                 INT           NULL,
        CONSTRAINT PK_PurchaseCharges PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_PurchaseCharges_Line UNIQUE (DocumentKind, DocumentId, LineNumber),
        CONSTRAINT CK_PurchaseCharges_Kind CHECK (DocumentKind IN (N'PINV', N'LCA')),
        CONSTRAINT CK_PurchaseCharges_Method CHECK (AllocationMethod IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual')),
        CONSTRAINT CK_PurchaseCharges_Amount CHECK (Amount >= 0),
        CONSTRAINT FK_PurchaseCharges_Type     FOREIGN KEY (ChargeTypeId)    REFERENCES purchase.ChargeTypes (Id),
        CONSTRAINT FK_PurchaseCharges_Provider FOREIGN KEY (ProviderPartyId) REFERENCES masterdata.Parties (Id),
        CONSTRAINT FK_PurchaseCharges_Currency FOREIGN KEY (CurrencyId)      REFERENCES masterdata.Currencies (Id)
    );
    CREATE NONCLUSTERED INDEX IX_PurchaseCharges_Document ON purchase.PurchaseCharges (DocumentKind, DocumentId);
    PRINT 'Created purchase.PurchaseCharges';
END
GO

IF OBJECT_ID(N'purchase.PurchaseChargeAllocations', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.PurchaseChargeAllocations
    (
        Id             INT IDENTITY(1,1) NOT NULL,
        ChargeId       INT           NOT NULL,
        PurchaseLineId INT           NOT NULL,     -- line of the PURCHASE INVOICE that receives the cost
        Basis          DECIMAL(18,6) NULL,         -- the share basis used (value, quantity, kg, cbm) - NULL for manual
        AmountBase     DECIMAL(18,2) NOT NULL,
        IsManual       BIT           NOT NULL CONSTRAINT DF_PurchaseChargeAllocations_Manual DEFAULT (0),
        CONSTRAINT PK_PurchaseChargeAllocations PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_PurchaseChargeAllocations UNIQUE (ChargeId, PurchaseLineId),
        CONSTRAINT FK_PurchaseChargeAllocations_Charge FOREIGN KEY (ChargeId)       REFERENCES purchase.PurchaseCharges (Id),
        CONSTRAINT FK_PurchaseChargeAllocations_Line   FOREIGN KEY (PurchaseLineId) REFERENCES purchase.PurchaseDocumentLines (Id)
    );
    CREATE NONCLUSTERED INDEX IX_PurchaseChargeAllocations_Line ON purchase.PurchaseChargeAllocations (PurchaseLineId);
    PRINT 'Created purchase.PurchaseChargeAllocations';
END
GO

IF TYPE_ID(N'purchase.tvp_PurchaseCharge') IS NULL
BEGIN
    CREATE TYPE purchase.tvp_PurchaseCharge AS TABLE
    (
        LineNumber                INT           NOT NULL PRIMARY KEY,
        ChargeTypeId              INT           NOT NULL,
        Description               NVARCHAR(200) NULL,
        ProviderPartyId           INT           NULL,
        Reference                 NVARCHAR(100) NULL,
        CurrencyId                INT           NULL,        -- NULL = document currency (invoice) / base currency (adjustment)
        RateType                  TINYINT       NULL,        -- NULL = 1 Official
        ExchangeRate              DECIMAL(18,6) NULL,        -- NULL = rate of the document date
        Amount                    DECIMAL(18,2) NOT NULL,
        AllocationMethod          NVARCHAR(10)  NULL,        -- NULL = the type's default
        IncludedInSupplierInvoice BIT           NULL,
        Notes                     NVARCHAR(300) NULL
    );
    PRINT 'Created type purchase.tvp_PurchaseCharge';
END
GO

IF TYPE_ID(N'purchase.tvp_ManualAllocation') IS NULL
BEGIN
    CREATE TYPE purchase.tvp_ManualAllocation AS TABLE
    (
        ChargeLineNumber INT           NOT NULL,
        PurchaseLineId   INT           NOT NULL,
        AmountBase       DECIMAL(18,2) NOT NULL,
        PRIMARY KEY (ChargeLineNumber, PurchaseLineId)
    );
    PRINT 'Created type purchase.tvp_ManualAllocation';
END
GO

-- Shared writer: replaces the charges of a document (PINV draft or LCA draft) and stores manual allocations.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseCharges_Write
    @DocumentKind      NVARCHAR(10),
    @DocumentId        INT,
    @DocumentDate      DATE,
    @DefaultCurrencyId INT,
    @TargetInvoiceId   INT,
    @Charges           purchase.tvp_PurchaseCharge READONLY,
    @ManualAllocations purchase.tvp_ManualAllocation READONLY,
    @UserId            INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Charge ' + CAST(c.LineNumber AS NVARCHAR(10)) + N': ' +
        CASE WHEN ct.Id IS NULL THEN N'charge type not found.'
             WHEN ct.IsActive = 0 THEN N'charge type ' + ct.ChargeName + N' is inactive.'
             WHEN c.Amount < 0 THEN N'amount cannot be negative.'
             WHEN c.AllocationMethod IS NOT NULL AND c.AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual') THEN N'unknown allocation method.'
             WHEN c.ExchangeRate IS NOT NULL AND c.ExchangeRate <= 0 THEN N'exchange rate must be greater than zero.'
             WHEN c.CurrencyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = c.CurrencyId AND IsActive = 1) THEN N'currency not found or inactive.'
             WHEN c.ProviderPartyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = c.ProviderPartyId AND IsActive = 1) THEN N'provider not found or inactive.' END
    FROM @Charges c
    LEFT JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    WHERE ct.Id IS NULL OR ct.IsActive = 0 OR c.Amount < 0
       OR (c.AllocationMethod IS NOT NULL AND c.AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual'))
       OR (c.ExchangeRate IS NOT NULL AND c.ExchangeRate <= 0)
       OR (c.CurrencyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = c.CurrencyId AND IsActive = 1))
       OR (c.ProviderPartyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = c.ProviderPartyId AND IsActive = 1))
    ORDER BY c.LineNumber;
    IF @Msg IS NOT NULL THROW 65012, @Msg, 1;

    -- Resolve currency + rate per charge (base currency -> 1).
    DECLARE @Resolved TABLE (LineNumber INT PRIMARY KEY, CurrencyId INT, RateType TINYINT, Rate DECIMAL(18,6), AmountBase DECIMAL(18,2), Method NVARCHAR(10), InLanded BIT);
    INSERT INTO @Resolved (LineNumber, CurrencyId, RateType, Rate, AmountBase, Method, InLanded)
    SELECT c.LineNumber, cur.Id, ISNULL(c.RateType, 1),
           r.Rate,
           ROUND(c.Amount / NULLIF(r.Rate, 0), 2),
           ISNULL(c.AllocationMethod, ct.AllocationMethod),
           ct.IncludeInLandedCost
    FROM @Charges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    CROSS APPLY (SELECT Id, IsBaseCurrency FROM masterdata.Currencies WHERE Id = ISNULL(c.CurrencyId, @DefaultCurrencyId)) cur
    CROSS APPLY (SELECT Rate = CASE WHEN cur.IsBaseCurrency = 1 THEN 1 ELSE COALESCE(c.ExchangeRate, masterdata.fn_GetRate(cur.Id, ISNULL(c.RateType, 1), @DocumentDate)) END) r;

    SELECT TOP (1) @Msg = N'Charge ' + CAST(LineNumber AS NVARCHAR(10)) + N': no exchange rate for its currency on ' + CONVERT(NVARCHAR(10), @DocumentDate, 120) + N' - add one or enter the rate.'
    FROM @Resolved WHERE Rate IS NULL ORDER BY LineNumber;
    IF @Msg IS NOT NULL THROW 65008, @Msg, 1;

    -- Manual allocations must match a Manual charge, reference lines of the target invoice and sum to the charge amount.
    IF EXISTS (SELECT 1 FROM @ManualAllocations m LEFT JOIN @Resolved r ON r.LineNumber = m.ChargeLineNumber WHERE r.LineNumber IS NULL OR r.Method <> N'Manual')
        THROW 65012, 'A manual allocation refers to a charge that does not exist or is not allocated manually.', 1;
    IF EXISTS (SELECT 1 FROM @ManualAllocations m WHERE NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines l WHERE l.Id = m.PurchaseLineId AND l.DocumentId = @TargetInvoiceId))
        THROW 65012, 'A manual allocation refers to a line that does not belong to the invoice.', 1;
    IF EXISTS (SELECT 1 FROM @ManualAllocations WHERE AmountBase < 0) THROW 65012, 'Manual allocation amounts cannot be negative.', 1;
    SELECT TOP (1) @Msg = N'Charge ' + CAST(r.LineNumber AS NVARCHAR(10)) + N': manual allocations (' + CAST(ISNULL(m.Total, 0) AS NVARCHAR(30)) + N') must equal the charge amount in base currency (' + CAST(r.AmountBase AS NVARCHAR(30)) + N').'
    FROM @Resolved r
    LEFT JOIN (SELECT ChargeLineNumber, Total = SUM(AmountBase) FROM @ManualAllocations GROUP BY ChargeLineNumber) m ON m.ChargeLineNumber = r.LineNumber
    WHERE r.Method = N'Manual' AND r.InLanded = 1 AND r.AmountBase > 0 AND ABS(ISNULL(m.Total, 0) - r.AmountBase) > 0.01
    ORDER BY r.LineNumber;
    IF @Msg IS NOT NULL THROW 65012, @Msg, 1;

    DELETE a FROM purchase.PurchaseChargeAllocations a INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId WHERE c.DocumentKind = @DocumentKind AND c.DocumentId = @DocumentId;
    DELETE FROM purchase.PurchaseCharges WHERE DocumentKind = @DocumentKind AND DocumentId = @DocumentId;

    INSERT INTO purchase.PurchaseCharges (DocumentKind, DocumentId, LineNumber, ChargeTypeId, Description, ProviderPartyId, Reference, CurrencyId, RateType, ExchangeRate,
                                          Amount, AmountBase, AllocationMethod, IncludeInLandedCost, IncludedInSupplierInvoice, Notes, CreatedBy)
    SELECT @DocumentKind, @DocumentId, c.LineNumber, c.ChargeTypeId, NULLIF(LTRIM(RTRIM(c.Description)), N''), c.ProviderPartyId, NULLIF(LTRIM(RTRIM(c.Reference)), N''),
           r.CurrencyId, r.RateType, r.Rate, c.Amount, r.AmountBase, r.Method, r.InLanded, ISNULL(c.IncludedInSupplierInvoice, 0), NULLIF(LTRIM(RTRIM(c.Notes)), N''), @UserId
    FROM @Charges c INNER JOIN @Resolved r ON r.LineNumber = c.LineNumber;

    INSERT INTO purchase.PurchaseChargeAllocations (ChargeId, PurchaseLineId, Basis, AmountBase, IsManual)
    SELECT pc.Id, m.PurchaseLineId, NULL, m.AmountBase, 1
    FROM @ManualAllocations m
    INNER JOIN purchase.PurchaseCharges pc ON pc.DocumentKind = @DocumentKind AND pc.DocumentId = @DocumentId AND pc.LineNumber = m.ChargeLineNumber
    WHERE pc.IncludeInLandedCost = 1;
END
GO

-- Charges of a DRAFT purchase invoice (allocation happens at posting).
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_SetCharges
    @DocumentId        INT,
    @Charges           purchase.tvp_PurchaseCharge READONLY,
    @ManualAllocations purchase.tvp_ManualAllocation READONLY,
    @RowVersion        BINARY(8) = NULL,
    @UserId            INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Date DATE, @CurrencyId INT;
    SELECT @Status = d.Status, @TypeCode = dt.Code, @Date = d.DocumentDate, @CurrencyId = d.CurrencyId
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @DocumentId;
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @TypeCode <> N'PINV' THROW 65010, 'Charges are entered on purchase invoices only (use a Landed Cost Adjustment after posting).', 1;
    IF @Status <> 1 THROW 65005, 'Charges can only be changed on a draft invoice.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @DocumentId AND RowVersion = @RowVersion)
        THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC purchase.usp_PurchaseCharges_Write N'PINV', @DocumentId, @Date, @CurrencyId, @DocumentId, @Charges, @ManualAllocations, @UserId;
        UPDATE purchase.PurchaseDocuments SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @DocumentId;
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@DocumentId, N'Updated', N'Charges saved: ' + CAST((SELECT COUNT(*) FROM @Charges) AS NVARCHAR(10)) + N' line(s)', @UserId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Allocates every landed, non-manual charge of (kind, document) over the lines of the target invoice.
-- Basis: Value = line total in base currency, Quantity = base units, Weight = base units x item WeightKg, Volume = base units x item VolumeCbm.
-- Rounded to 2 decimals; the rounding remainder goes to the line with the largest basis, so the sum equals the charge.
CREATE OR ALTER PROCEDURE purchase.usp_PurchaseCharges_Allocate
    @DocumentKind    NVARCHAR(10),
    @DocumentId      INT,
    @TargetInvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rate DECIMAL(18,6) = (SELECT ExchangeRate FROM purchase.PurchaseDocuments WHERE Id = @TargetInvoiceId);

    DECLARE @Lines TABLE (LineId INT PRIMARY KEY, LineNumber INT, ItemCode NVARCHAR(30), ValueBase DECIMAL(18,6), QtyBase INT, WeightKg DECIMAL(18,3), VolumeCbm DECIMAL(18,4));
    INSERT INTO @Lines (LineId, LineNumber, ItemCode, ValueBase, QtyBase, WeightKg, VolumeCbm)
    SELECT l.Id, l.LineNumber, i.ItemCode, l.LineTotal / @Rate, l.QuantityBase, i.WeightKg, i.VolumeCbm
    FROM purchase.PurchaseDocumentLines l INNER JOIN inventory.Items i ON i.Id = l.ItemId
    WHERE l.DocumentId = @TargetInvoiceId;

    DECLARE @ChargeId INT, @LineNo INT, @Method NVARCHAR(10), @Amount DECIMAL(18,2), @Msg NVARCHAR(400);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT Id, LineNumber, AllocationMethod, AmountBase FROM purchase.PurchaseCharges
        WHERE DocumentKind = @DocumentKind AND DocumentId = @DocumentId AND IncludeInLandedCost = 1 AND AllocationMethod <> N'Manual'
        ORDER BY LineNumber;
    OPEN cur;
    FETCH NEXT FROM cur INTO @ChargeId, @LineNo, @Method, @Amount;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DELETE FROM purchase.PurchaseChargeAllocations WHERE ChargeId = @ChargeId AND IsManual = 0;

        IF @Method = N'Weight' AND EXISTS (SELECT 1 FROM @Lines WHERE WeightKg IS NULL)
        BEGIN
            SELECT TOP (1) @Msg = N'Charge ' + CAST(@LineNo AS NVARCHAR(10)) + N': item ' + ItemCode + N' has no weight (kg) - set it in Item Definition or change the allocation method.' FROM @Lines WHERE WeightKg IS NULL ORDER BY LineNumber;
            THROW 65012, @Msg, 1;
        END
        IF @Method = N'Volume' AND EXISTS (SELECT 1 FROM @Lines WHERE VolumeCbm IS NULL)
        BEGIN
            SELECT TOP (1) @Msg = N'Charge ' + CAST(@LineNo AS NVARCHAR(10)) + N': item ' + ItemCode + N' has no volume (CBM) - set it in Item Definition or change the allocation method.' FROM @Lines WHERE VolumeCbm IS NULL ORDER BY LineNumber;
            THROW 65012, @Msg, 1;
        END

        DECLARE @Basis TABLE (LineId INT PRIMARY KEY, Basis DECIMAL(18,6));
        DELETE FROM @Basis;
        INSERT INTO @Basis (LineId, Basis)
        SELECT LineId, CASE @Method WHEN N'Value' THEN ValueBase WHEN N'Quantity' THEN QtyBase WHEN N'Weight' THEN QtyBase * WeightKg WHEN N'Volume' THEN QtyBase * VolumeCbm END
        FROM @Lines;

        DECLARE @Total DECIMAL(18,6) = (SELECT SUM(Basis) FROM @Basis);
        IF @Total IS NULL OR @Total <= 0
        BEGIN
            SET @Msg = N'Charge ' + CAST(@LineNo AS NVARCHAR(10)) + N': the allocation basis (' + @Method + N') is zero for every line - use another method or a manual allocation.';
            THROW 65012, @Msg, 1;
        END

        INSERT INTO purchase.PurchaseChargeAllocations (ChargeId, PurchaseLineId, Basis, AmountBase, IsManual)
        SELECT @ChargeId, LineId, Basis, ROUND(@Amount * Basis / @Total, 2), 0 FROM @Basis;

        DECLARE @Remainder DECIMAL(18,2) = @Amount - (SELECT SUM(AmountBase) FROM purchase.PurchaseChargeAllocations WHERE ChargeId = @ChargeId);
        IF @Remainder <> 0
            UPDATE a SET AmountBase = a.AmountBase + @Remainder
            FROM purchase.PurchaseChargeAllocations a
            WHERE a.Id = (SELECT TOP (1) a2.Id FROM purchase.PurchaseChargeAllocations a2 INNER JOIN @Basis b ON b.LineId = a2.PurchaseLineId
                          WHERE a2.ChargeId = @ChargeId ORDER BY b.Basis DESC, a2.PurchaseLineId);

        FETCH NEXT FROM cur INTO @ChargeId, @LineNo, @Method, @Amount;
    END
    CLOSE cur; DEALLOCATE cur;
END
GO

/* ================================================================== 6. Purchase documents re-created (FOB / landed / charges) */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Save
    @Id                 INT            = NULL,
    @DocumentTypeCode   NVARCHAR(20),
    @DocumentDate       DATE,
    @ExpectedDate       DATE           = NULL,
    @BranchId           INT,
    @WarehouseId        INT,
    @SupplierId         INT,
    @CurrencyId         INT            = NULL,
    @RateType           TINYINT        = 1,
    @ExchangeRate       DECIMAL(18,6)  = NULL,
    @SupplierReference  NVARCHAR(100)  = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @Lines              purchase.tvp_PurchaseDocumentLine READONLY,
    @MaxDiscountPercent DECIMAL(9,4)   = 100,
    @SourceDocumentId   INT            = NULL,
    @RowVersion         BINARY(8)      = NULL,
    @UserId             INT            = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SupplierReference = NULLIF(LTRIM(RTRIM(@SupplierReference)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

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
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30) = NULL;
            IF EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Id = @TypeId AND NumberOnPost = 0)
                EXEC inventory.usp_DocumentType_NextNumber @DocumentTypeCode, @Number OUTPUT, @BranchId;

            INSERT INTO purchase.PurchaseDocuments (DocumentTypeId, DocumentNumber, DocumentDate, ExpectedDate, BranchId, WarehouseId, SupplierId,
                                                    CurrencyId, RateType, ExchangeRate, SupplierReference, Notes, Status, SourceDocumentId, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @ExpectedDate, @BranchId, @WarehouseId, @SupplierId,
                    @Cur, @RateType, @Rate, @SupplierReference, @Notes, 1, @SourceDocumentId, @UserId);
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
                SupplierReference = @SupplierReference, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

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

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE,
                @BranchId INT, @SupplierId INT, @Rate DECIMAL(18,6), @SourceId INT;

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @SupplierId = d.SupplierId, @Rate = d.ExchangeRate, @SourceId = d.SourceDocumentId
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status <> 1 THROW 65010, 'Only draft documents can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id)
            THROW 65009, 'The document has no lines. Add at least one item before posting.', 1;
        IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @SupplierId AND IsActive = 1)
            THROW 65008, 'The supplier is inactive.', 1;

        DECLARE @Msg NVARCHAR(400);
        SELECT TOP (1) @Msg =
            CASE WHEN i.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': item ' + i.ItemCode + N' is inactive.'
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM purchase.PurchaseDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
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

        IF @Direction = 1
        BEGIN
            DECLARE @R inventory.tvp_ItemReceipt;
            INSERT INTO @R (ItemId, QuantityBase, UnitCostBase, FobCostBase)
            SELECT l.ItemId, l.QuantityBase, ISNULL(l.UnitCostBase, 0), l.FobCostBase FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = @Id;
            EXEC inventory.usp_Item_ApplyReceipts @R, @SupplierId, @UserId, 1;
        END

        IF @Direction <> 0
        BEGIN
            DECLARE @MovementDate DATETIME2(3) =
                DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@DocumentDate AS DATETIME2(3)));

            INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                                  DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, CreatedBy)
            SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Purchase', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM purchase.PurchaseDocumentLines l
            WHERE l.DocumentId = @Id;
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
                                + CASE WHEN @Direction <> 0 THEN N' written to the stock ledger' ELSE N' (order confirmed)' END
                                + CASE WHEN @TypeCode = N'PINV' THEN N'; landed charges ' + CAST((SELECT TotalChargesBase FROM purchase.PurchaseDocuments WHERE Id = @Id) AS NVARCHAR(30)) ELSE N'' END, @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 65000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @SourceId INT, @Number NVARCHAR(30);
        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @SourceId = d.SourceDocumentId, @Number = d.DocumentNumber
        FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 65006, 'Document not found.', 1;
        IF @Status NOT IN (2, 4) THROW 65010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 65004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE SourceDocumentId = @Id AND Status IN (2, 4))
            THROW 65011, 'This document cannot be cancelled: posted documents were created from it. Cancel those first.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE SourceInvoiceId = @Id AND Status = 2)
            THROW 65011, 'This invoice cannot be cancelled: posted landed cost adjustments refer to it. Cancel those first.', 1;

        DECLARE @Msg NVARCHAR(400);
        IF @Direction = 1
        BEGIN
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 65007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentId = @Id AND m.IsReversal = 0;

        IF @SourceId IS NOT NULL AND @TypeCode = N'PINV'
        BEGIN
            UPDATE s SET ReceivedQuantityBase = s.ReceivedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

            IF EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @SourceId AND Status = 4 AND CloseReason = N'Fully received')
            BEGIN
                UPDATE purchase.PurchaseDocuments SET Status = 2, ClosedAtUtc = NULL, ClosedBy = NULL, CloseReason = NULL WHERE Id = @SourceId;
                INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@SourceId, N'Updated', N'Re-opened: ' + @Number + N' was cancelled', @UserId);
            END
        END
        IF @SourceId IS NOT NULL AND @TypeCode = N'PRET'
        BEGIN
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase - x.Qty
            FROM purchase.PurchaseDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;
        END

        UPDATE purchase.PurchaseDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        -- A cancelled receipt / return changes the cost history: replay the ledger for the items concerned.
        IF @Direction <> 0
        BEGIN
            DECLARE @ItemId INT;
            DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;
            OPEN items; FETCH NEXT FROM items INTO @ItemId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC inventory.usp_Item_RebuildCosts @ItemId;
                FETCH NEXT FROM items INTO @ItemId;
            END
            CLOSE items; DEALLOCATE items;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT = (SELECT Status FROM purchase.PurchaseDocuments WHERE Id = @Id);
    IF @Status IS NULL THROW 65006, 'Document not found.', 1;
    IF @Status <> 1 THROW 65005, 'Only draft documents can be deleted. Posted documents must be cancelled.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE a FROM purchase.PurchaseChargeAllocations a INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId WHERE c.DocumentKind = N'PINV' AND c.DocumentId = @Id;
        DELETE FROM purchase.PurchaseCharges WHERE DocumentKind = N'PINV' AND DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentFiles WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentLines WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocumentAudit WHERE DocumentId = @Id;
        DELETE FROM purchase.PurchaseDocuments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 7. Landed Cost Adjustments (charges arriving after receipt) */

MERGE inventory.DocumentTypes AS t
USING (VALUES (N'LCA', N'Landed Cost Adjustment', N'Purchase', 0, N'LCA-', 0, 0)) AS s (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
ON t.Code = s.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Family, StockDirection, NumberPrefix, NumberOnPost, RequiresReason)
    VALUES (s.Code, s.Name, s.Family, s.StockDirection, s.NumberPrefix, s.NumberOnPost, s.RequiresReason);
UPDATE inventory.DocumentTypes SET DefaultPricing = N'None', PriceEditable = 0 WHERE Code = N'LCA';
GO

IF OBJECT_ID(N'purchase.LandedCostAdjustments', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.LandedCostAdjustments
    (
        Id                   INT IDENTITY(1,1) NOT NULL,
        DocumentTypeId       INT            NOT NULL,
        DocumentNumber       NVARCHAR(30)   NOT NULL,
        DocumentDate         DATE           NOT NULL,
        BranchId             INT            NOT NULL,
        SourceInvoiceId      INT            NOT NULL,     -- posted purchase invoice
        Notes                NVARCHAR(1000) NULL,
        Status               TINYINT        NOT NULL CONSTRAINT DF_LandedCostAdjustments_Status DEFAULT (1),   -- 1 Draft, 2 Posted, 3 Cancelled
        TotalChargesBase     DECIMAL(18,2)  NOT NULL CONSTRAINT DF_LandedCostAdjustments_Total DEFAULT (0),      -- landed charges only
        InventoryPortionBase DECIMAL(18,2)  NOT NULL CONSTRAINT DF_LandedCostAdjustments_Inv DEFAULT (0),
        CogsPortionBase      DECIMAL(18,2)  NOT NULL CONSTRAINT DF_LandedCostAdjustments_Cogs DEFAULT (0),
        PostedAtUtc          DATETIME2(3)   NULL,
        PostedBy             INT            NULL,
        CancelledAtUtc       DATETIME2(3)   NULL,
        CancelledBy          INT            NULL,
        CancelReason         NVARCHAR(300)  NULL,
        CreatedAtUtc         DATETIME2(3)   NOT NULL CONSTRAINT DF_LandedCostAdjustments_CreatedAtUtc DEFAULT (SYSUTCDATETIME()),
        CreatedBy            INT            NULL,
        UpdatedAtUtc         DATETIME2(3)   NULL,
        UpdatedBy            INT            NULL,
        RowVersion           ROWVERSION     NOT NULL,
        CONSTRAINT PK_LandedCostAdjustments PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_LandedCostAdjustments_Number UNIQUE (DocumentNumber),
        CONSTRAINT CK_LandedCostAdjustments_Status CHECK (Status IN (1, 2, 3)),
        CONSTRAINT FK_LandedCostAdjustments_Type      FOREIGN KEY (DocumentTypeId)  REFERENCES inventory.DocumentTypes (Id),
        CONSTRAINT FK_LandedCostAdjustments_Branch    FOREIGN KEY (BranchId)        REFERENCES masterdata.Branches (Id),
        CONSTRAINT FK_LandedCostAdjustments_Invoice   FOREIGN KEY (SourceInvoiceId) REFERENCES purchase.PurchaseDocuments (Id),
        CONSTRAINT FK_LandedCostAdjustments_PostedBy  FOREIGN KEY (PostedBy)        REFERENCES security.Users (Id),
        CONSTRAINT FK_LandedCostAdjustments_CreatedBy FOREIGN KEY (CreatedBy)       REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_LandedCostAdjustments_Invoice ON purchase.LandedCostAdjustments (SourceInvoiceId, Status);
    PRINT 'Created purchase.LandedCostAdjustments';
END
GO

IF OBJECT_ID(N'purchase.LandedCostAdjustmentLines', N'U') IS NULL
BEGIN
    CREATE TABLE purchase.LandedCostAdjustmentLines
    (
        Id                   INT IDENTITY(1,1) NOT NULL,
        AdjustmentId         INT           NOT NULL,
        PurchaseLineId       INT           NOT NULL,
        ItemId               INT           NOT NULL,
        WarehouseId          INT           NOT NULL,
        ReceivedBase         INT           NOT NULL,     -- invoice line quantity (base units)
        NetReceivedBase      INT           NOT NULL,     -- received - returned
        RemainingBase        INT           NOT NULL,     -- still in stock (approximation, see header)
        AllocatedBase        DECIMAL(18,2) NOT NULL,     -- charges allocated to the line
        ExtraPerBaseUnit     DECIMAL(18,6) NOT NULL,     -- AllocatedBase / ReceivedBase
        InventoryPortionBase DECIMAL(18,2) NOT NULL,
        CogsPortionBase      DECIMAL(18,2) NOT NULL,
        LandedCostBefore     DECIMAL(18,6) NOT NULL,
        LandedCostAfter      DECIMAL(18,6) NOT NULL,
        CONSTRAINT PK_LandedCostAdjustmentLines PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT UQ_LandedCostAdjustmentLines UNIQUE (AdjustmentId, PurchaseLineId),
        CONSTRAINT FK_LandedCostAdjustmentLines_Adj  FOREIGN KEY (AdjustmentId)   REFERENCES purchase.LandedCostAdjustments (Id),
        CONSTRAINT FK_LandedCostAdjustmentLines_Line FOREIGN KEY (PurchaseLineId) REFERENCES purchase.PurchaseDocumentLines (Id)
    );
    PRINT 'Created purchase.LandedCostAdjustmentLines';
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Search
    @Search          NVARCHAR(100) = NULL,   -- number, invoice number, supplier
    @SourceInvoiceId INT          = NULL,
    @BranchId        INT          = NULL,
    @Status          TINYINT      = NULL,
    @DateFrom        DATE         = NULL,
    @DateTo          DATE         = NULL,
    @PageNumber      INT          = 1,
    @PageSize        INT          = 10
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');

    SELECT a.Id, a.DocumentNumber, a.DocumentDate, a.BranchId, b.BranchName, a.SourceInvoiceId, inv.DocumentNumber AS SourceInvoiceNumber,
           inv.SupplierId, sp.PartyName AS SupplierName, a.Status, a.TotalChargesBase, a.InventoryPortionBase, a.CogsPortionBase,
           a.PostedAtUtc, pu.FullName AS PostedByName, a.CreatedAtUtc, cu.FullName AS CreatedByName, a.RowVersion,
           COUNT(*) OVER () AS TotalCount
    FROM purchase.LandedCostAdjustments a
    INNER JOIN masterdata.Branches b ON b.Id = a.BranchId
    INNER JOIN purchase.PurchaseDocuments inv ON inv.Id = a.SourceInvoiceId
    INNER JOIN masterdata.Parties sp ON sp.Id = inv.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = a.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = a.PostedBy
    WHERE (@Search IS NULL OR a.DocumentNumber LIKE N'%' + @Search + N'%' OR inv.DocumentNumber LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%')
      AND (@SourceInvoiceId IS NULL OR a.SourceInvoiceId = @SourceInvoiceId)
      AND (@BranchId IS NULL OR a.BranchId = @BranchId)
      AND (@Status IS NULL OR a.Status = @Status)
      AND (@DateFrom IS NULL OR a.DocumentDate >= @DateFrom)
      AND (@DateTo IS NULL OR a.DocumentDate <= @DateTo)
    ORDER BY a.DocumentDate DESC, a.Id DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- Three result sets: header, charges (with their allocations summarised), lines (the split - filled at posting).
CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT a.Id, a.DocumentNumber, a.DocumentDate, a.BranchId, b.BranchName, a.SourceInvoiceId, inv.DocumentNumber AS SourceInvoiceNumber,
           inv.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, inv.WarehouseId, w.WarehouseName,
           a.Notes, a.Status, a.TotalChargesBase, a.InventoryPortionBase, a.CogsPortionBase,
           a.PostedAtUtc, a.PostedBy, pu.FullName AS PostedByName, a.CancelledAtUtc, a.CancelReason,
           a.CreatedAtUtc, a.CreatedBy, cu.FullName AS CreatedByName, a.UpdatedAtUtc, a.RowVersion
    FROM purchase.LandedCostAdjustments a
    INNER JOIN masterdata.Branches b ON b.Id = a.BranchId
    INNER JOIN purchase.PurchaseDocuments inv ON inv.Id = a.SourceInvoiceId
    INNER JOIN masterdata.Warehouses w ON w.Id = inv.WarehouseId
    INNER JOIN masterdata.Parties sp ON sp.Id = inv.SupplierId
    LEFT  JOIN security.Users cu ON cu.Id = a.CreatedBy
    LEFT  JOIN security.Users pu ON pu.Id = a.PostedBy
    WHERE a.Id = @Id;

    SELECT c.Id, c.LineNumber, c.ChargeTypeId, ct.ChargeCode, ct.ChargeName, c.Description, c.ProviderPartyId, pp.PartyName AS ProviderName, c.Reference,
           c.CurrencyId, cur.CurrencyCode, c.RateType, c.ExchangeRate, c.Amount, c.AmountBase, c.AllocationMethod, c.IncludeInLandedCost, c.IncludedInSupplierInvoice, c.Notes,
           AllocatedBase = (SELECT SUM(AmountBase) FROM purchase.PurchaseChargeAllocations x WHERE x.ChargeId = c.Id)
    FROM purchase.PurchaseCharges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = c.CurrencyId
    LEFT  JOIN masterdata.Parties pp ON pp.Id = c.ProviderPartyId
    WHERE c.DocumentKind = N'LCA' AND c.DocumentId = @Id
    ORDER BY c.LineNumber;

    SELECT l.Id, l.PurchaseLineId, pl.LineNumber, l.ItemId, i.ItemCode, i.ItemName, l.WarehouseId, w.WarehouseCode,
           l.ReceivedBase, l.NetReceivedBase, l.RemainingBase, l.AllocatedBase, l.ExtraPerBaseUnit, l.InventoryPortionBase, l.CogsPortionBase,
           l.LandedCostBefore, l.LandedCostAfter
    FROM purchase.LandedCostAdjustmentLines l
    INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = l.PurchaseLineId
    INNER JOIN inventory.Items i ON i.Id = l.ItemId
    INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
    WHERE l.AdjustmentId = @Id
    ORDER BY pl.LineNumber;
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Save
    @Id                INT            = NULL,
    @SourceInvoiceId   INT,
    @DocumentDate      DATE,
    @Notes             NVARCHAR(1000) = NULL,
    @Charges           purchase.tvp_PurchaseCharge READONLY,
    @ManualAllocations purchase.tvp_ManualAllocation READONLY,
    @RowVersion        BINARY(8)      = NULL,
    @UserId            INT            = NULL,
    @NewId             INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @DocumentDate IS NULL THROW 67000, 'Date is required.', 1;
    IF @DocumentDate > CAST(SYSUTCDATETIME() AS DATE) THROW 67000, 'Date cannot be in the future.', 1;

    DECLARE @InvStatus TINYINT, @InvType NVARCHAR(20), @BranchId INT, @BaseCurrency INT = (SELECT TOP (1) Id FROM masterdata.Currencies WHERE IsBaseCurrency = 1 AND IsActive = 1);
    SELECT @InvStatus = d.Status, @InvType = dt.Code, @BranchId = d.BranchId
    FROM purchase.PurchaseDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceInvoiceId;
    IF @InvStatus IS NULL THROW 67011, 'Purchase invoice not found.', 1;
    IF @InvType <> N'PINV' OR @InvStatus <> 2 THROW 67011, 'Landed cost adjustments apply to POSTED purchase invoices only.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Charges) THROW 67000, 'At least one charge is required.', 1;

    IF @Id IS NOT NULL
    BEGIN
        DECLARE @Status TINYINT = (SELECT Status FROM purchase.LandedCostAdjustments WHERE Id = @Id);
        IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
        IF @Status <> 1 THROW 67005, 'Only draft adjustments can be edited.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 67004, 'This adjustment was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND SourceInvoiceId <> @SourceInvoiceId)
            THROW 67000, 'The invoice of an adjustment cannot be changed.', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;
        IF @Id IS NULL
        BEGIN
            DECLARE @Number NVARCHAR(30), @TypeId INT = (SELECT Id FROM inventory.DocumentTypes WHERE Code = N'LCA');
            EXEC inventory.usp_DocumentType_NextNumber N'LCA', @Number OUTPUT, @BranchId;
            INSERT INTO purchase.LandedCostAdjustments (DocumentTypeId, DocumentNumber, DocumentDate, BranchId, SourceInvoiceId, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @BranchId, @SourceInvoiceId, @Notes, 1, @UserId);
            SET @Id = SCOPE_IDENTITY();
        END
        ELSE
            UPDATE purchase.LandedCostAdjustments SET DocumentDate = @DocumentDate, Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;

        EXEC purchase.usp_PurchaseCharges_Write N'LCA', @Id, @DocumentDate, @BaseCurrency, @SourceInvoiceId, @Charges, @ManualAllocations, @UserId;

        UPDATE a SET TotalChargesBase = ISNULL((SELECT SUM(AmountBase) FROM purchase.PurchaseCharges WHERE DocumentKind = N'LCA' AND DocumentId = @Id AND IncludeInLandedCost = 1), 0)
        FROM purchase.LandedCostAdjustments a WHERE a.Id = @Id;

        SET @NewId = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Posting: allocate over the invoice lines, split between stock still on hand (inventory value, average recalculated)
-- and quantity already sold (COGS adjustment), update the invoice lines' landed cost and the item's last cost.
CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @InvoiceId INT, @Number NVARCHAR(30), @Date DATE, @BranchId INT;
        SELECT @Status = Status, @InvoiceId = SourceInvoiceId, @Number = DocumentNumber, @Date = DocumentDate, @BranchId = BranchId
        FROM purchase.LandedCostAdjustments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
        IF @Status <> 1 THROW 67010, 'Only draft adjustments can be posted.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 67004, 'This adjustment was modified by another user. Reload the page and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId AND Status = 2)
            THROW 67011, 'The purchase invoice is no longer posted.', 1;

        EXEC purchase.usp_PurchaseCharges_Allocate N'LCA', @Id, @InvoiceId;

        DECLARE @Rate DECIMAL(18,6) = (SELECT ExchangeRate FROM purchase.PurchaseDocuments WHERE Id = @InvoiceId);

        DELETE FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id;
        INSERT INTO purchase.LandedCostAdjustmentLines (AdjustmentId, PurchaseLineId, ItemId, WarehouseId, ReceivedBase, NetReceivedBase, RemainingBase,
                                                        AllocatedBase, ExtraPerBaseUnit, InventoryPortionBase, CogsPortionBase, LandedCostBefore, LandedCostAfter)
        SELECT @Id, l.Id, l.ItemId, l.WarehouseId, l.QuantityBase, n.NetReceived, r.Remaining,
               a.Allocated, a.Allocated / l.QuantityBase,
               InvPortion = ROUND(a.Allocated / l.QuantityBase * r.Remaining, 2),
               CogsPortion = a.Allocated - ROUND(a.Allocated / l.QuantityBase * r.Remaining, 2),
               l.UnitCostBase,
               ((l.LineTotal / @Rate) + l.AllocatedChargesBase + a.Allocated) / l.QuantityBase
        FROM purchase.PurchaseDocumentLines l
        CROSS APPLY (SELECT Allocated = ISNULL((SELECT SUM(x.AmountBase) FROM purchase.PurchaseChargeAllocations x
                                                 INNER JOIN purchase.PurchaseCharges c ON c.Id = x.ChargeId
                                                 WHERE x.PurchaseLineId = l.Id AND c.DocumentKind = N'LCA' AND c.DocumentId = @Id AND c.IncludeInLandedCost = 1), 0)) a
        CROSS APPLY (SELECT NetReceived = l.QuantityBase - l.ReturnedQuantityBase) n
        CROSS APPLY (SELECT Remaining = CASE WHEN inventory.fn_StockOnHand(l.ItemId, l.WarehouseId) < n.NetReceived
                                             THEN CASE WHEN inventory.fn_StockOnHand(l.ItemId, l.WarehouseId) > 0 THEN inventory.fn_StockOnHand(l.ItemId, l.WarehouseId) ELSE 0 END
                                             ELSE n.NetReceived END) r
        WHERE l.DocumentId = @InvoiceId AND a.Allocated <> 0;

        -- Items with no stock at all: everything goes to COGS.
        UPDATE x SET CogsPortionBase = x.CogsPortionBase + x.InventoryPortionBase, InventoryPortionBase = 0
        FROM purchase.LandedCostAdjustmentLines x
        WHERE x.AdjustmentId = @Id AND inventory.fn_StockOnHand(x.ItemId, NULL) <= 0;

        -- Inventory value -> moving average (company-wide: value added / total on hand of the item).
        UPDATE i SET AverageCost = i.AverageCost + p.Inv / inventory.fn_StockOnHand(i.Id, NULL)
        FROM inventory.Items i
        INNER JOIN (SELECT ItemId, Inv = SUM(InventoryPortionBase) FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id GROUP BY ItemId) p ON p.ItemId = i.Id
        WHERE p.Inv <> 0 AND inventory.fn_StockOnHand(i.Id, NULL) > 0;

        -- Invoice lines / header carry the new landed cost.
        UPDATE l SET AllocatedChargesBase = l.AllocatedChargesBase + x.AllocatedBase, UnitCostBase = x.LandedCostAfter
        FROM purchase.PurchaseDocumentLines l INNER JOIN purchase.LandedCostAdjustmentLines x ON x.PurchaseLineId = l.Id
        WHERE x.AdjustmentId = @Id;
        UPDATE d SET TotalChargesBase = ISNULL(x.Charges, 0), TotalLandedCostBase = d.TotalAmountBase + ISNULL(x.Charges, 0)
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT SUM(AllocatedChargesBase) AS Charges FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId) x
        WHERE d.Id = @InvoiceId;

        -- Last cost follows when this invoice is the item's latest posted purchase.
        UPDATE i SET LastCost = x.LandedCostAfter
        FROM inventory.Items i
        INNER JOIN purchase.LandedCostAdjustmentLines x ON x.ItemId = i.Id AND x.AdjustmentId = @Id
        WHERE @InvoiceId = (SELECT TOP (1) d.Id FROM purchase.PurchaseDocumentLines l
                            INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
                            INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                            WHERE dt.Code = N'PINV' AND d.Status = 2 AND l.ItemId = i.Id ORDER BY d.PostedAtUtc DESC, l.Id DESC);

        -- Value ledger.
        INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
        SELECT DATEADD(SECOND, DATEDIFF(SECOND, CAST(SYSUTCDATETIME() AS DATE), SYSUTCDATETIME()), CAST(@Date AS DATETIME2(3))),
               x.ItemId, x.WarehouseId, @BranchId, k.Kind, k.Amount, N'LCA', @Id, @Number, x.PurchaseLineId, @UserId
        FROM purchase.LandedCostAdjustmentLines x
        CROSS APPLY (VALUES (N'Inventory', x.InventoryPortionBase), (N'COGS', x.CogsPortionBase)) k (Kind, Amount)
        WHERE x.AdjustmentId = @Id AND k.Amount <> 0;

        UPDATE a
        SET Status = 2, PostedAtUtc = SYSUTCDATETIME(), PostedBy = @UserId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId,
            InventoryPortionBase = ISNULL(t.Inv, 0), CogsPortionBase = ISNULL(t.Cogs, 0)
        FROM purchase.LandedCostAdjustments a
        CROSS APPLY (SELECT SUM(InventoryPortionBase) AS Inv, SUM(CogsPortionBase) AS Cogs FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id) t
        WHERE a.Id = @Id;

        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId)
        VALUES (@InvoiceId, N'Updated', N'Landed cost adjustment ' + @Number + N' posted: ' + CAST((SELECT TotalChargesBase FROM purchase.LandedCostAdjustments WHERE Id = @Id) AS NVARCHAR(30)) + N' added to the landed cost', @UserId);

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 67000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @Status TINYINT, @InvoiceId INT, @Number NVARCHAR(30), @BranchId INT;
        SELECT @Status = Status, @InvoiceId = SourceInvoiceId, @Number = DocumentNumber, @BranchId = BranchId
        FROM purchase.LandedCostAdjustments WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
        IF @Status <> 2 THROW 67010, 'Only posted adjustments can be cancelled.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.LandedCostAdjustments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 67004, 'This adjustment was modified by another user. Reload the page and try again.', 1;

        -- Reverse the value ledger and the invoice landed cost.
        INSERT INTO inventory.CostAdjustments (AdjustmentDate, ItemId, WarehouseId, BranchId, Kind, AmountBase, SourceKind, SourceId, SourceNumber, PurchaseLineId, CreatedBy)
        SELECT SYSUTCDATETIME(), c.ItemId, c.WarehouseId, c.BranchId, c.Kind, -c.AmountBase, c.SourceKind, c.SourceId, c.SourceNumber, c.PurchaseLineId, @UserId
        FROM inventory.CostAdjustments c WHERE c.SourceKind = N'LCA' AND c.SourceId = @Id AND c.AmountBase > 0;

        UPDATE l SET AllocatedChargesBase = l.AllocatedChargesBase - x.AllocatedBase, UnitCostBase = x.LandedCostBefore
        FROM purchase.PurchaseDocumentLines l INNER JOIN purchase.LandedCostAdjustmentLines x ON x.PurchaseLineId = l.Id
        WHERE x.AdjustmentId = @Id;
        UPDATE d SET TotalChargesBase = ISNULL(x.Charges, 0), TotalLandedCostBase = d.TotalAmountBase + ISNULL(x.Charges, 0)
        FROM purchase.PurchaseDocuments d
        CROSS APPLY (SELECT SUM(AllocatedChargesBase) AS Charges FROM purchase.PurchaseDocumentLines WHERE DocumentId = @InvoiceId) x
        WHERE d.Id = @InvoiceId;

        UPDATE purchase.LandedCostAdjustments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        INSERT INTO purchase.PurchaseDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@InvoiceId, N'Updated', N'Landed cost adjustment ' + @Number + N' cancelled: ' + @Reason, @UserId);

        -- Average / last cost recomputed from the ledger (the reversal rows net the adjustment out).
        DECLARE @ItemId INT;
        DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id;
        OPEN items; FETCH NEXT FROM items INTO @ItemId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC inventory.usp_Item_RebuildCosts @ItemId;
            FETCH NEXT FROM items INTO @ItemId;
        END
        CLOSE items; DEALLOCATE items;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE purchase.usp_LandedCostAdjustment_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status TINYINT = (SELECT Status FROM purchase.LandedCostAdjustments WHERE Id = @Id);
    IF @Status IS NULL THROW 67006, 'Adjustment not found.', 1;
    IF @Status <> 1 THROW 67005, 'Only draft adjustments can be deleted.', 1;
    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE a FROM purchase.PurchaseChargeAllocations a INNER JOIN purchase.PurchaseCharges c ON c.Id = a.ChargeId WHERE c.DocumentKind = N'LCA' AND c.DocumentId = @Id;
        DELETE FROM purchase.PurchaseCharges WHERE DocumentKind = N'LCA' AND DocumentId = @Id;
        DELETE FROM purchase.LandedCostAdjustmentLines WHERE AdjustmentId = @Id;
        DELETE FROM purchase.LandedCostAdjustments WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 8. purchase.usp_PurchaseDocument_Get re-created (cost columns + 6th result set: charges) */

CREATE OR ALTER PROCEDURE purchase.usp_PurchaseDocument_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id, d.DocumentTypeId, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.StockDirection, dt.NumberOnPost,
           d.DocumentNumber, d.DocumentDate, d.ExpectedDate,
           d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName, sp.Phone AS SupplierPhone, sp.Email AS SupplierEmail, sp.Address AS SupplierAddress,
           d.CurrencyId, c.CurrencyCode, c.CurrencyName, c.Symbol AS CurrencySymbol, c.DecimalPlaces, c.IsBaseCurrency,
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.SupplierReference, d.Notes, d.Status,
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase, d.TotalChargesBase, d.TotalLandedCostBase,
           d.SourceDocumentId, src.DocumentNumber AS SourceDocumentNumber, sdt.Code AS SourceDocumentTypeCode,
           d.SourceShortageId, sh.DocumentNumber AS SourceShortageNumber,
           d.PostedAtUtc, d.PostedBy, pu.FullName AS PostedByName,
           d.CancelledAtUtc, d.CancelledBy, xu.FullName AS CancelledByName, d.CancelReason,
           d.ClosedAtUtc, d.ClosedBy, ku.FullName AS ClosedByName, d.CloseReason,
           d.CreatedAtUtc, d.CreatedBy, cu.FullName AS CreatedByName, d.UpdatedAtUtc, d.UpdatedBy, uu.FullName AS UpdatedByName,
           d.RowVersion
    FROM purchase.PurchaseDocuments d
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
    INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
    INNER JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
    INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies c    ON c.Id = d.CurrencyId
    LEFT  JOIN masterdata.Currencies bc   ON bc.IsBaseCurrency = 1 AND bc.IsActive = 1
    LEFT  JOIN purchase.PurchaseDocuments src ON src.Id = d.SourceDocumentId
    LEFT  JOIN inventory.DocumentTypes sdt ON sdt.Id = src.DocumentTypeId
    LEFT  JOIN inventory.ShortageDocuments sh ON sh.Id = d.SourceShortageId
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    LEFT  JOIN security.Users ku ON ku.Id = d.ClosedBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal,
           l.UnitCostBase, LandedCostBase = l.UnitCostBase, l.FobCostBase, l.AllocatedChargesBase,
           l.ReceivedQuantityBase, l.ReturnedQuantityBase, l.ShippedQuantityBase,
           TransitBase = CASE WHEN l.ShippedQuantityBase > l.ReceivedQuantityBase THEN l.ShippedQuantityBase - l.ReceivedQuantityBase ELSE 0 END,
           RemainingBase = CASE WHEN dt.Code = N'PO' THEN l.QuantityBase - l.ReceivedQuantityBase
                                WHEN dt.Code = N'PINV' THEN l.QuantityBase - l.ReturnedQuantityBase END,
           l.ImportRowNumber, l.Notes, l.SourceLineId,
           OnHandBase  = inventory.fn_StockOnHand(l.ItemId, l.WarehouseId),
           ItemLastCost = i.LastCost, ItemAverageCost = i.AverageCost, ItemFobCost = i.FobCost
    FROM purchase.PurchaseDocumentLines l
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = l.DocumentId
    INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
    INNER JOIN inventory.Items i            ON i.Id = l.ItemId
    INNER JOIN inventory.ItemUnits iu       ON iu.Id = l.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut      ON ut.Id = iu.UnitTypeId
    INNER JOIN masterdata.Warehouses w      ON w.Id = l.WarehouseId
    WHERE l.DocumentId = @Id
    ORDER BY l.LineNumber;

    SELECT f.Id, f.DocumentId, f.FileName, f.ContentType, f.SizeBytes, f.CreatedAtUtc, u.FullName AS CreatedByName
    FROM purchase.PurchaseDocumentFiles f
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.DocumentId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM purchase.PurchaseDocumentAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.DocumentId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;

    SELECT Relation = N'Source', x.Id, dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments d
    INNER JOIN purchase.PurchaseDocuments x ON x.Id = d.SourceDocumentId
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE d.Id = @Id
    UNION ALL
    SELECT N'Child', x.Id, dt.Code, dt.Name, x.DocumentNumber, x.DocumentDate, x.Status, x.TotalAmount, c.CurrencyCode
    FROM purchase.PurchaseDocuments x
    INNER JOIN inventory.DocumentTypes dt ON dt.Id = x.DocumentTypeId
    INNER JOIN masterdata.Currencies c ON c.Id = x.CurrencyId
    WHERE x.SourceDocumentId = @Id
    ORDER BY Relation DESC, DocumentDate, Id;

    -- 6: charges of the invoice (kind PINV) and of its posted / draft adjustments (kind LCA), with the allocated total.
    SELECT c.Id, c.DocumentKind, c.DocumentId, SourceNumber = CASE WHEN c.DocumentKind = N'LCA' THEN lca.DocumentNumber ELSE d.DocumentNumber END,
           c.LineNumber, c.ChargeTypeId, ct.ChargeCode, ct.ChargeName, c.Description, c.ProviderPartyId, pp.PartyName AS ProviderName, c.Reference,
           c.CurrencyId, cur.CurrencyCode, c.RateType, c.ExchangeRate, c.Amount, c.AmountBase, c.AllocationMethod, c.IncludeInLandedCost, c.IncludedInSupplierInvoice, c.Notes,
           AllocatedBase = (SELECT SUM(AmountBase) FROM purchase.PurchaseChargeAllocations x WHERE x.ChargeId = c.Id),
           AdjustmentStatus = lca.Status
    FROM purchase.PurchaseCharges c
    INNER JOIN purchase.ChargeTypes ct ON ct.Id = c.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = c.CurrencyId
    LEFT  JOIN masterdata.Parties pp ON pp.Id = c.ProviderPartyId
    LEFT  JOIN purchase.PurchaseDocuments d ON d.Id = c.DocumentId AND c.DocumentKind = N'PINV'
    LEFT  JOIN purchase.LandedCostAdjustments lca ON lca.Id = c.DocumentId AND c.DocumentKind = N'LCA'
    WHERE (c.DocumentKind = N'PINV' AND c.DocumentId = @Id)
       OR (c.DocumentKind = N'LCA' AND lca.SourceInvoiceId = @Id)
    ORDER BY c.DocumentKind, c.DocumentId, c.LineNumber;
END
GO

/* ================================================================== 9. Inventory In / Out: receipts do not touch Last Cost */

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
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM inventory.StockDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
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
        SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase,
               CASE WHEN l.PackingFormula > 0 THEN l.UnitCost / l.PackingFormula END,
               N'Inventory', @TypeCode, @Id, l.Id, @Number, @ReasonCode, l.ExpiryDate, @UserId
        FROM inventory.StockDocumentLines l
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

/* ================================================================== 10. Sales: cost snapshots, return consumption, profit */

IF COL_LENGTH(N'sales.SalesDocumentLines', N'CogsBase') IS NULL
BEGIN
    ALTER TABLE sales.SalesDocumentLines ADD
        FobCostAtSale        DECIMAL(18,6) NULL,      -- item FOB cost at posting (analysis)
        LastCostAtSale       DECIMAL(18,6) NULL,      -- item last (landed) cost at posting (analysis)
        NetSalesBase         DECIMAL(18,2) NULL,      -- LineTotal / rate
        CogsBase             DECIMAL(18,2) NULL,      -- QuantityBase x UnitCostBase (frozen)
        GrossProfitBase      DECIMAL(18,2) NULL,
        GrossProfitPct       DECIMAL(9,2)  NULL,      -- on net sales
        ReturnedQuantityBase INT           NOT NULL CONSTRAINT DF_SalesDocumentLines_Returned DEFAULT (0);
    PRINT 'SalesDocumentLines: added cost / profit snapshot columns, ReturnedQuantityBase';
END
GO

IF COL_LENGTH(N'sales.SalesDocuments', N'TotalGrossProfitBase') IS NULL
BEGIN
    ALTER TABLE sales.SalesDocuments ADD TotalGrossProfitBase DECIMAL(18,2) NOT NULL CONSTRAINT DF_SalesDocuments_GrossProfit DEFAULT (0);
    PRINT 'SalesDocuments: added TotalGrossProfitBase';
END
GO

-- Backfill the snapshots of invoices posted before this script (COGS was already frozen per line).
UPDATE l
SET NetSalesBase = ROUND(l.LineTotal / d.ExchangeRate, 2),
    CogsBase = ROUND(l.QuantityBase * ISNULL(l.UnitCostBase, 0), 2),
    GrossProfitBase = ROUND(l.LineTotal / d.ExchangeRate, 2) - ROUND(l.QuantityBase * ISNULL(l.UnitCostBase, 0), 2),
    GrossProfitPct = CASE WHEN l.LineTotal > 0 THEN ROUND(100.0 * (ROUND(l.LineTotal / d.ExchangeRate, 2) - ROUND(l.QuantityBase * ISNULL(l.UnitCostBase, 0), 2)) / ROUND(l.LineTotal / d.ExchangeRate, 2), 2) END
FROM sales.SalesDocumentLines l
INNER JOIN sales.SalesDocuments d ON d.Id = l.DocumentId
WHERE d.Status IN (2, 3) AND l.CogsBase IS NULL;
UPDATE d SET TotalGrossProfitBase = ISNULL(x.Gp, 0)
FROM sales.SalesDocuments d
CROSS APPLY (SELECT SUM(GrossProfitBase) AS Gp FROM sales.SalesDocumentLines WHERE DocumentId = d.Id) x
WHERE d.Status IN (2, 3) AND d.TotalGrossProfitBase = 0 AND x.Gp IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Save
    @Id                 INT            = NULL,
    @DocumentTypeCode   NVARCHAR(20)   = N'SINV',
    @DocumentDate       DATE,
    @DueDate            DATE           = NULL,
    @BranchId           INT,
    @WarehouseId        INT,
    @ClientId           INT,
    @SalesmanId         INT            = NULL,
    @PriceListId        INT,
    @RateType           TINYINT        = 1,
    @ExchangeRate       DECIMAL(18,6)  = NULL,
    @ReferenceNo        NVARCHAR(100)  = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @Lines              sales.tvp_SalesDocumentLine READONLY,
    @AllowPriceOverride BIT            = 0,
    @MaxDiscountPercent DECIMAL(9,4)   = 100,
    @DraftReference     NVARCHAR(50)   = NULL,
    @RowVersion         BINARY(8)      = NULL,
    @UserId             INT            = NULL,
    @NewId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @DraftReference = NULLIF(LTRIM(RTRIM(@DraftReference)), N'');

    DECLARE @TypeId INT, @Direction SMALLINT, @CurrencyId INT, @Rate DECIMAL(18,6);
    EXEC sales.usp_SalesDocument_ValidateInput @DocumentTypeCode, @DocumentDate, @DueDate, @BranchId, @WarehouseId, @ClientId, @SalesmanId,
         @PriceListId, @RateType, @ExchangeRate, @MaxDiscountPercent, @Lines,
         @TypeId OUTPUT, @Direction OUTPUT, @CurrencyId OUTPUT, @Rate OUTPUT;

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
        LineNumber INT PRIMARY KEY, ItemId INT, ItemUnitId INT, ExpiryDate DATE, Quantity INT, PackingFormula INT,
        UnitPrice DECIMAL(18,4) NULL, SystemPrice DECIMAL(18,4) NULL, DiscountPercent DECIMAL(9,4), ImportRowNumber INT, Notes NVARCHAR(300)
    );
    INSERT INTO @Priced (LineNumber, ItemId, ItemUnitId, ExpiryDate, Quantity, PackingFormula, UnitPrice, SystemPrice, DiscountPercent, ImportRowNumber, Notes)
    SELECT l.LineNumber, l.ItemId, l.ItemUnitId, l.ExpiryDate, l.Quantity, iu.PackingFormula,
           CASE WHEN @AllowPriceOverride = 1 AND l.UnitPrice IS NOT NULL THEN l.UnitPrice ELSE sp.Price END,
           sp.Price, ISNULL(l.DiscountPercent, 0), l.ImportRowNumber, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
    FROM @Lines l
    INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId
    CROSS APPLY (SELECT masterdata.fn_GetUnitPrice(l.ItemUnitId, @PriceListId, @BranchId) AS Price) sp;

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
                                              PriceListId, CurrencyId, RateType, ExchangeRate, ReferenceNo, Notes, Status, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @DueDate, @BranchId, @WarehouseId, @ClientId, @SalesmanId,
                    @PriceListId, @CurrencyId, @RateType, @Rate, @ReferenceNo, @Notes, 1, @UserId);
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
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM sales.SalesDocumentLines WHERE DocumentId = @Id;

            INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId)
            VALUES (@Id, N'Updated', N'Header and ' + CAST((SELECT COUNT(*) FROM @Lines) AS NVARCHAR(10)) + N' line(s) saved', @UserId);
        END

        INSERT INTO sales.SalesDocumentLines (DocumentId, LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, PackingFormula,
                                              UnitPrice, DiscountPercent, PriceSource, UnitCostBase, ImportRowNumber, Notes, SourceLineId)
        SELECT @Id, p.LineNumber, p.ItemId, p.ItemUnitId, @WarehouseId, p.ExpiryDate, p.Quantity, p.PackingFormula,
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

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Post
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @TypeCode NVARCHAR(20), @Direction SMALLINT, @Number NVARCHAR(30), @DocumentDate DATE, @BranchId INT,
                @Rate DECIMAL(18,6), @SourceId INT;

        SELECT @Status = d.Status, @TypeCode = dt.Code, @Direction = dt.StockDirection, @Number = d.DocumentNumber,
               @DocumentDate = d.DocumentDate, @BranchId = d.BranchId, @Rate = d.ExchangeRate, @SourceId = d.SourceDocumentId
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
                 WHEN w.IsActive = 0 THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is inactive.'
                 WHEN w.BranchId <> @BranchId THEN N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': warehouse ' + w.WarehouseCode + N' is not in the document branch.' END
        FROM sales.SalesDocumentLines l
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.Warehouses w ON w.Id = l.WarehouseId
        WHERE l.DocumentId = @Id AND (i.IsActive = 0 OR w.IsActive = 0 OR w.BranchId <> @BranchId)
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 64000, @Msg, 1;

        IF NOT EXISTS (SELECT 1 FROM sales.SalesDocuments d INNER JOIN masterdata.Parties p ON p.Id = d.ClientId WHERE d.Id = @Id AND p.IsActive = 1)
            THROW 64008, 'The client is inactive.', 1;

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

        IF @Direction = -1
        BEGIN
            SELECT TOP (1) @Msg = N'Insufficient stock for ' + i.ItemCode + N' in ' + w.WarehouseCode + N': available '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N', required ' + CAST(x.Qty AS NVARCHAR(20)) + N' (base units).'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 64007, @Msg, 1;
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
            SELECT @MovementDate, l.ItemId, l.WarehouseId, @BranchId, @Direction * l.QuantityBase, l.UnitCostBase,
                   N'Sales', @TypeCode, @Id, l.Id, @Number, NULL, l.ExpiryDate, @UserId
            FROM sales.SalesDocumentLines l
            WHERE l.DocumentId = @Id;
        END

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

        COMMIT TRANSACTION;
        SELECT @Number AS DocumentNumber;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_Cancel
    @Id         INT,
    @Reason     NVARCHAR(300),
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL THROW 64000, 'A cancellation reason is required.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Status TINYINT, @Direction SMALLINT, @TypeCode NVARCHAR(20), @SourceId INT;
        SELECT @Status = d.Status, @Direction = dt.StockDirection, @TypeCode = dt.Code, @SourceId = d.SourceDocumentId
        FROM sales.SalesDocuments d WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        WHERE d.Id = @Id;

        IF @Status IS NULL THROW 64006, 'Document not found.', 1;
        IF @Status <> 2 THROW 64010, 'Only posted documents can be cancelled (delete drafts instead).', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 64004, 'This document was modified by another user. Reload the page and try again.', 1;
        IF EXISTS (SELECT 1 FROM sales.SalesDocuments WHERE SourceDocumentId = @Id AND Status = 2)
            THROW 64010, 'This invoice cannot be cancelled: posted returns refer to it. Cancel those first.', 1;

        IF @Direction = 1
        BEGIN
            DECLARE @Msg NVARCHAR(400);
            SELECT TOP (1) @Msg = N'Cannot cancel: ' + i.ItemCode + N' in ' + w.WarehouseCode + N' has only '
                                 + CAST(inventory.fn_StockOnHand(x.ItemId, x.WarehouseId) AS NVARCHAR(20)) + N' left, but this document added ' + CAST(x.Qty AS NVARCHAR(20)) + N'.'
            FROM (SELECT ItemId, WarehouseId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id GROUP BY ItemId, WarehouseId) x
            INNER JOIN inventory.Items i ON i.Id = x.ItemId
            INNER JOIN masterdata.Warehouses w ON w.Id = x.WarehouseId
            WHERE x.Qty > inventory.fn_StockOnHand(x.ItemId, x.WarehouseId)
            ORDER BY i.ItemCode;
            IF @Msg IS NOT NULL THROW 64007, @Msg, 1;
        END

        INSERT INTO inventory.StockMovements (MovementDate, ItemId, WarehouseId, BranchId, QuantityBase, UnitCostBase,
                                              DocumentFamily, DocumentTypeCode, DocumentId, DocumentLineId, DocumentNumber, ReasonCode, ExpiryDate, IsReversal, CreatedBy)
        SELECT SYSUTCDATETIME(), m.ItemId, m.WarehouseId, m.BranchId, -m.QuantityBase, m.UnitCostBase,
               m.DocumentFamily, m.DocumentTypeCode, m.DocumentId, m.DocumentLineId, m.DocumentNumber, m.ReasonCode, m.ExpiryDate, 1, @UserId
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Sales' AND m.DocumentId = @Id AND m.IsReversal = 0;

        IF @TypeCode = N'SRET' AND @SourceId IS NOT NULL
            UPDATE s SET ReturnedQuantityBase = s.ReturnedQuantityBase - x.Qty
            FROM sales.SalesDocumentLines s
            INNER JOIN (SELECT SourceLineId, SUM(QuantityBase) AS Qty FROM sales.SalesDocumentLines WHERE DocumentId = @Id AND SourceLineId IS NOT NULL GROUP BY SourceLineId) x ON x.SourceLineId = s.Id;

        UPDATE sales.SalesDocuments
        SET Status = 3, CancelledAtUtc = SYSUTCDATETIME(), CancelledBy = @UserId, CancelReason = @Reason,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@Id, N'Cancelled', @Reason, @UserId);

        -- A cancelled return was a receipt: replay the cost history of its items.
        IF @Direction = 1
        BEGIN
            DECLARE @ItemId INT;
            DECLARE items CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ItemId FROM sales.SalesDocumentLines WHERE DocumentId = @Id;
            OPEN items; FETCH NEXT FROM items INTO @ItemId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC inventory.usp_Item_RebuildCosts @ItemId;
                FETCH NEXT FROM items INTO @ItemId;
            END
            CLOSE items; DEALLOCATE items;
        END

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
           d.RateType, d.ExchangeRate, bc.CurrencyCode AS BaseCurrencyCode,
           d.ReferenceNo, d.Notes, d.Status,
           d.TotalItems, d.TotalQuantity, d.Subtotal, d.TotalDiscount, d.TotalAmount, d.TotalAmountBase, d.TotalCostBase, d.TotalGrossProfitBase,
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
    LEFT  JOIN security.Users cu ON cu.Id = d.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = d.UpdatedBy
    LEFT  JOIN security.Users pu ON pu.Id = d.PostedBy
    LEFT  JOIN security.Users xu ON xu.Id = d.CancelledBy
    WHERE d.Id = @Id;

    SELECT l.Id, l.DocumentId, l.LineNumber, l.ItemId, i.ItemCode, i.ItemName,
           l.ItemUnitId, ut.UnitTypeName, iu.SkuCode, iu.Barcode, l.PackingFormula,
           l.WarehouseId, w.WarehouseCode, w.WarehouseName, l.ExpiryDate,
           l.Quantity, l.QuantityBase, l.UnitPrice, l.DiscountPercent, l.LineDiscount, l.LineTotal, l.PriceSource,
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

-- Sales return draft from a posted invoice: remaining quantities, invoice prices, ORIGINAL COGS per line.
CREATE OR ALTER PROCEDURE sales.usp_SalesDocument_CreateFromSource
    @SourceId     INT,
    @DocumentDate DATE = NULL,
    @UserId       INT  = NULL,
    @NewId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @DocumentDate IS NULL SET @DocumentDate = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @SrcType NVARCHAR(20), @Status TINYINT, @BranchId INT, @WarehouseId INT, @ClientId INT, @SalesmanId INT, @PriceListId INT, @RateType TINYINT, @Rate DECIMAL(18,6), @Ref NVARCHAR(100);
    SELECT @SrcType = dt.Code, @Status = d.Status, @BranchId = d.BranchId, @WarehouseId = d.WarehouseId, @ClientId = d.ClientId, @SalesmanId = d.SalesmanId,
           @PriceListId = d.PriceListId, @RateType = d.RateType, @Rate = d.ExchangeRate, @Ref = d.DocumentNumber
    FROM sales.SalesDocuments d INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId WHERE d.Id = @SourceId;
    IF @SrcType IS NULL THROW 64006, 'Source invoice not found.', 1;
    IF @SrcType <> N'SINV' OR @Status <> 2 THROW 64010, 'Returns are created from POSTED sales invoices only.', 1;
    IF NOT EXISTS (SELECT 1 FROM inventory.DocumentTypes WHERE Code = N'SRET' AND IsActive = 1) THROW 64008, 'Document type SRET is inactive.', 1;

    DECLARE @Lines sales.tvp_SalesDocumentLine;
    INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, WarehouseId, ExpiryDate, Quantity, UnitPrice, DiscountPercent, ImportRowNumber, Notes)
    SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber), l.ItemId, c.ItemUnitId, l.WarehouseId, l.ExpiryDate, c.Quantity, c.UnitPrice, l.DiscountPercent, NULL, l.Notes
    FROM sales.SalesDocumentLines l
    CROSS APPLY (SELECT Remaining = l.QuantityBase - l.ReturnedQuantityBase) r
    CROSS APPLY (SELECT ItemUnitId = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.ItemUnitId
                                          ELSE (SELECT TOP (1) Id FROM inventory.ItemUnits WHERE ItemId = l.ItemId AND IsBaseUnit = 1) END,
                        Quantity   = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN r.Remaining / l.PackingFormula ELSE r.Remaining END,
                        UnitPrice  = CASE WHEN r.Remaining % l.PackingFormula = 0 THEN l.UnitPrice ELSE ROUND(l.UnitPrice / l.PackingFormula, 4) END) c
    WHERE l.DocumentId = @SourceId AND r.Remaining > 0;
    IF NOT EXISTS (SELECT 1 FROM @Lines) THROW 64010, 'Everything on this invoice was already returned.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Saved with the override allowed so the invoice prices are kept as given; then linked to the source lines.
        EXEC sales.usp_SalesDocument_Save @Id = NULL, @DocumentTypeCode = N'SRET', @DocumentDate = @DocumentDate, @DueDate = NULL,
             @BranchId = @BranchId, @WarehouseId = @WarehouseId, @ClientId = @ClientId, @SalesmanId = @SalesmanId, @PriceListId = @PriceListId,
             @RateType = @RateType, @ExchangeRate = @Rate, @ReferenceNo = @Ref, @Notes = NULL, @Lines = @Lines,
             @AllowPriceOverride = 1, @MaxDiscountPercent = 100, @DraftReference = NULL, @RowVersion = NULL, @UserId = @UserId, @NewId = @NewId OUTPUT;

        UPDATE n
        SET SourceLineId = s.Id, UnitCostBase = s.UnitCostBase
        FROM sales.SalesDocumentLines n
        INNER JOIN (SELECT ROW_NUMBER() OVER (ORDER BY l.LineNumber) AS Rn, l.Id, l.UnitCostBase
                    FROM sales.SalesDocumentLines l WHERE l.DocumentId = @SourceId AND l.QuantityBase - l.ReturnedQuantityBase > 0) s ON s.Rn = n.LineNumber
        WHERE n.DocumentId = @NewId;

        UPDATE sales.SalesDocuments SET SourceDocumentId = @SourceId WHERE Id = @NewId;
        INSERT INTO sales.SalesDocumentAudit (DocumentId, Action, Details, UserId) VALUES (@NewId, N'Created', N'Return draft created from ' + @Ref, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ================================================================== 11. Sales profit report (frozen costs) */

-- Net Sales, COGS, Gross Profit and GP % in the base currency from the posted invoice lines (returns subtract),
-- plus the COGS adjustments of landed cost adjustments in the period (separate column - they belong to no invoice).
CREATE OR ALTER PROCEDURE sales.usp_SalesProfit_Report
    @DateFrom     DATE         = NULL,
    @DateTo       DATE         = NULL,
    @BranchId     INT          = NULL,
    @ClientId     INT          = NULL,
    @SalesmanId   INT          = NULL,
    @ItemFamilyId INT          = NULL,
    @BrandId      INT          = NULL,
    @ItemId       INT          = NULL,
    @GroupBy      NVARCHAR(20) = N'Invoice'   -- Invoice | Item | Family | Brand | Client | Salesman | Branch | Month | All
AS
BEGIN
    SET NOCOUNT ON;
    IF @GroupBy IS NULL OR @GroupBy NOT IN (N'Invoice', N'Item', N'Family', N'Brand', N'Client', N'Salesman', N'Branch', N'Month', N'All') SET @GroupBy = N'Invoice';

    ;WITH lines AS
    (
        SELECT d.Id AS DocumentId, d.DocumentNumber, d.DocumentDate, d.BranchId, b.BranchName, d.ClientId, cl.PartyName AS ClientName,
               d.SalesmanId, sm.PartyName AS SalesmanName, l.ItemId, i.ItemCode, i.ItemName, i.ItemFamilyId, f.FamilyName, i.BrandId, br.BrandName,
               Sign = CASE WHEN dt.Code = N'SRET' THEN -1 ELSE 1 END,
               l.QuantityBase, GrossBase = ROUND(l.Quantity * l.UnitPrice / d.ExchangeRate, 2), l.NetSalesBase, l.CogsBase, l.GrossProfitBase
        FROM sales.SalesDocumentLines l
        INNER JOIN sales.SalesDocuments d ON d.Id = l.DocumentId
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
        INNER JOIN inventory.Items i ON i.Id = l.ItemId
        INNER JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
        INNER JOIN masterdata.Brands br ON br.Id = i.BrandId
        INNER JOIN masterdata.Branches b ON b.Id = d.BranchId
        INNER JOIN masterdata.Parties cl ON cl.Id = d.ClientId
        LEFT  JOIN masterdata.Parties sm ON sm.Id = d.SalesmanId
        WHERE d.Status = 2 AND dt.Code IN (N'SINV', N'SRET')
          AND (@DateFrom IS NULL OR d.DocumentDate >= @DateFrom)
          AND (@DateTo IS NULL OR d.DocumentDate <= @DateTo)
          AND (@BranchId IS NULL OR d.BranchId = @BranchId)
          AND (@ClientId IS NULL OR d.ClientId = @ClientId)
          AND (@SalesmanId IS NULL OR d.SalesmanId = @SalesmanId)
          AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
          AND (@BrandId IS NULL OR i.BrandId = @BrandId)
          AND (@ItemId IS NULL OR l.ItemId = @ItemId)
    ),
    keyed AS
    (
        SELECT *,
               GroupKey = CASE @GroupBy WHEN N'Invoice' THEN CAST(DocumentId AS NVARCHAR(30)) WHEN N'Item' THEN CAST(ItemId AS NVARCHAR(30))
                                        WHEN N'Family' THEN CAST(ItemFamilyId AS NVARCHAR(30)) WHEN N'Brand' THEN CAST(BrandId AS NVARCHAR(30))
                                        WHEN N'Client' THEN CAST(ClientId AS NVARCHAR(30)) WHEN N'Salesman' THEN CAST(ISNULL(SalesmanId, 0) AS NVARCHAR(30))
                                        WHEN N'Branch' THEN CAST(BranchId AS NVARCHAR(30)) WHEN N'Month' THEN CONVERT(NVARCHAR(7), DocumentDate, 120) ELSE N'ALL' END,
               GroupLabel = CASE @GroupBy WHEN N'Invoice' THEN DocumentNumber WHEN N'Item' THEN ItemCode + N' - ' + ItemName WHEN N'Family' THEN FamilyName
                                          WHEN N'Brand' THEN BrandName WHEN N'Client' THEN ClientName WHEN N'Salesman' THEN ISNULL(SalesmanName, N'(no salesman)')
                                          WHEN N'Branch' THEN BranchName WHEN N'Month' THEN CONVERT(NVARCHAR(7), DocumentDate, 120) ELSE N'All' END
        FROM lines
    )
    SELECT k.GroupKey, k.GroupLabel,
           InvoiceCount   = COUNT(DISTINCT CASE WHEN k.Sign = 1 THEN k.DocumentId END),
           ReturnCount    = COUNT(DISTINCT CASE WHEN k.Sign = -1 THEN k.DocumentId END),
           QuantityBase   = SUM(k.Sign * k.QuantityBase),
           GrossSalesBase = SUM(k.Sign * k.GrossBase),
           DiscountBase   = SUM(k.Sign * (k.GrossBase - ISNULL(k.NetSalesBase, 0))),
           NetSalesBase   = SUM(k.Sign * ISNULL(k.NetSalesBase, 0)),
           CogsBase       = SUM(k.Sign * ISNULL(k.CogsBase, 0)),
           GrossProfitBase = SUM(k.Sign * ISNULL(k.GrossProfitBase, 0)),
           GrossProfitPct = CASE WHEN SUM(k.Sign * ISNULL(k.NetSalesBase, 0)) <> 0
                                 THEN ROUND(100.0 * SUM(k.Sign * ISNULL(k.GrossProfitBase, 0)) / SUM(k.Sign * ISNULL(k.NetSalesBase, 0)), 2) END,
           CogsAdjustmentsBase = CASE WHEN @GroupBy IN (N'All', N'Month', N'Branch', N'Item', N'Family', N'Brand')
                                      THEN ISNULL((SELECT SUM(c.AmountBase) FROM inventory.CostAdjustments c
                                                   INNER JOIN inventory.Items ci ON ci.Id = c.ItemId
                                                   WHERE c.Kind = N'COGS'
                                                     AND (@DateFrom IS NULL OR CAST(c.AdjustmentDate AS DATE) >= @DateFrom)
                                                     AND (@DateTo IS NULL OR CAST(c.AdjustmentDate AS DATE) <= @DateTo)
                                                     AND (@BranchId IS NULL OR c.BranchId = @BranchId)
                                                     AND (@ItemFamilyId IS NULL OR ci.ItemFamilyId IN (SELECT Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId)))
                                                     AND (@BrandId IS NULL OR ci.BrandId = @BrandId)
                                                     AND (@ItemId IS NULL OR c.ItemId = @ItemId)
                                                     AND (@GroupBy <> N'Month' OR CONVERT(NVARCHAR(7), c.AdjustmentDate, 120) = k.GroupKey)
                                                     AND (@GroupBy <> N'Branch' OR CAST(c.BranchId AS NVARCHAR(30)) = k.GroupKey)
                                                     AND (@GroupBy <> N'Item' OR CAST(c.ItemId AS NVARCHAR(30)) = k.GroupKey)
                                                     AND (@GroupBy <> N'Family' OR CAST(ci.ItemFamilyId AS NVARCHAR(30)) = k.GroupKey)
                                                     AND (@GroupBy <> N'Brand' OR CAST(ci.BrandId AS NVARCHAR(30)) = k.GroupKey)), 0)
                                      ELSE 0 END
    FROM keyed k
    GROUP BY k.GroupKey, k.GroupLabel
    ORDER BY CASE WHEN @GroupBy IN (N'Invoice', N'Month') THEN k.GroupKey END DESC, k.GroupLabel;
END
GO

/* ================================================================== 12. Permissions + report */

MERGE security.Permissions AS target
USING
(
    VALUES
        (N'purchase.chargetypes.manage', N'Manage purchase charge types', N'Configuration', N'Define charge types and their allocation rules.',          910),
        (N'purchase.landedcosts.view',   N'View Landed Cost Adjustments',   N'Purchase', N'See landed cost adjustments.',                               1180),
        (N'purchase.landedcosts.create', N'Create Landed Cost Adjustments', N'Purchase', N'Create and edit draft landed cost adjustments.',             1190),
        (N'purchase.landedcosts.post',   N'Post Landed Cost Adjustments',   N'Purchase', N'Post landed cost adjustments (updates item costs).',         1200),
        (N'purchase.landedcosts.cancel', N'Cancel Landed Cost Adjustments', N'Purchase', N'Cancel posted landed cost adjustments.',                     1210),
        (N'purchase.landedcosts.delete', N'Delete Landed Cost Adjustments', N'Purchase', N'Delete draft landed cost adjustments.',                      1220),
        (N'sales.profit.view',           N'View Sales Profit',              N'Sales',    N'See the sales profit report (net sales, COGS, gross profit).', 680)
) AS source (Code, Name, Module, Description, SortOrder)
ON target.Code = source.Code
WHEN MATCHED THEN
    UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Code, Name, Module, Description, SortOrder)
    VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder);
GO

INSERT INTO security.RolePermissions (RoleId, PermissionId)
SELECT r.Id, p.Id
FROM security.Roles r
CROSS JOIN security.Permissions p
WHERE (p.Code LIKE N'purchase.landedcosts.%' OR p.Code IN (N'purchase.chargetypes.manage', N'sales.profit.view'))
  AND (r.IsSystem = 1 OR (r.Name = N'Manager' AND p.Code IN (N'purchase.landedcosts.view', N'sales.profit.view')))
  AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = p.Id);
GO

SELECT ChargeCode, ChargeName, AllocationMethod, IncludeInLandedCost, IsRecoverableTax FROM purchase.ChargeTypes ORDER BY Id;
SELECT Code, Name, NumberPrefix FROM inventory.DocumentTypes WHERE Code IN (N'PINV', N'LCA');
SELECT TOP (10) ItemCode, FobCost, LastCost, AverageCost, InventoryValue FROM inventory.vw_InventoryValuation ORDER BY ItemCode;
PRINT 'Item costing is ready: FOB -> landed (charges) -> moving average -> frozen COGS -> gross profit.';
GO
