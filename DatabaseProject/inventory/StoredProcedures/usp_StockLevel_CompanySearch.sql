/* (91) INVENTORY > STOCK LEVELS, "Company (Item Definition)" (L2): the item's company Minimum / Maximum Quantity against
   the stock of a branch or the company. Result 1: the items with a company Min (above 0) or a Max, Below Min first by
   what is missing, then item code; WarehouseLevelCount = the item's levels at the active warehouses of the scope (what
   "Per warehouse" shows for the item with the same branch). Result 2: the scope's totals (the status filter ignored):
   with the defaults, BelowMin is the Dashboard's "Items below their minimum" for the same branch. Result 3: the scope
   (BranchId NULL = the company). */
CREATE   PROCEDURE inventory.usp_StockLevel_CompanySearch
    @Search          NVARCHAR(100) = NULL,
    @BranchId        INT           = NULL,
    @ItemFamilyId    INT           = NULL,
    @BrandId         INT           = NULL,
    @Status          NVARCHAR(20)  = NULL,
    @ActiveItemsOnly BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;

    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @Status = NULLIF(LTRIM(RTRIM(@Status)), N'');
    SET @ActiveItemsOnly = ISNULL(@ActiveItemsOnly, 1);

    IF @Status IS NOT NULL AND @Status NOT IN (N'BelowMin', N'AboveMax', N'Ok')
        THROW 56000, 'Unknown status: choose Below Min, Above Max or OK.', 1;

    -- (91) THE DASHBOARD'S OWN FORMULA (reporting.usp_Dashboard_Summary, script 72): the stock of EVERY warehouse of the
    --      branch - inactive ones and its On the way warehouse included - or of the company, against the item's company
    --      Minimum Quantity. Change one, change both (test f compares them).
    DECLARE @Stock TABLE (ItemId INT NOT NULL PRIMARY KEY, OnHand INT NOT NULL);
    INSERT INTO @Stock (ItemId, OnHand)
    SELECT m.ItemId, SUM(m.QuantityBase)
    FROM inventory.StockMovements m
    INNER JOIN masterdata.Warehouses w ON w.Id = m.WarehouseId
    WHERE @BranchId IS NULL OR w.BranchId = @BranchId
    GROUP BY m.ItemId;

    CREATE TABLE #co
    (
        ItemId INT NOT NULL PRIMARY KEY, OnHandBase INT NOT NULL, Status NVARCHAR(10) NOT NULL, MissingBase INT NOT NULL
    );
    INSERT INTO #co (ItemId, OnHandBase, Status, MissingBase)
    SELECT i.Id, s.OnHand,
           CASE WHEN i.MinQuantity > 0 AND s.OnHand < i.MinQuantity               THEN N'BelowMin'
                WHEN i.MaxQuantity IS NOT NULL AND s.OnHand > i.MaxQuantity       THEN N'AboveMax'
                ELSE N'Ok' END,
           CASE WHEN i.MinQuantity > 0 AND s.OnHand < i.MinQuantity THEN i.MinQuantity - s.OnHand ELSE 0 END
    FROM inventory.Items i
    CROSS APPLY (SELECT OnHand = ISNULL((SELECT st.OnHand FROM @Stock st WHERE st.ItemId = i.Id), 0)) s
    WHERE (i.MinQuantity > 0 OR i.MaxQuantity IS NOT NULL)
      AND (@ActiveItemsOnly = 0 OR i.IsActive = 1)
      AND (@BrandId IS NULL OR i.BrandId = @BrandId)
      AND (@ItemFamilyId IS NULL OR i.ItemFamilyId IN (SELECT f.Id FROM masterdata.fn_ItemFamily_Subtree(@ItemFamilyId) f))
      AND (@Search IS NULL OR i.ItemCode LIKE N'%' + @Search + N'%' OR i.ItemName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM inventory.ItemUnits u WHERE u.ItemId = i.Id AND u.Barcode = @Search));

    -- 1: the items
    SELECT c.ItemId, i.ItemCode, i.ItemName, ItemIsActive = i.IsActive, ItemFamilyName = f.FamilyName, b.BrandName,
           c.OnHandBase, i.MinQuantity, i.MaxQuantity, c.Status, c.MissingBase,
           WarehouseLevelCount = (SELECT COUNT(*)
                                  FROM inventory.ItemWarehouseLevels lv
                                  INNER JOIN masterdata.Warehouses w ON w.Id = lv.WarehouseId AND w.IsActive = 1
                                  WHERE lv.ItemId = c.ItemId AND (@BranchId IS NULL OR w.BranchId = @BranchId))
    FROM #co c
    INNER JOIN inventory.Items i         ON i.Id = c.ItemId
    LEFT  JOIN masterdata.ItemFamilies f ON f.Id = i.ItemFamilyId
    LEFT  JOIN masterdata.Brands b       ON b.Id = i.BrandId
    WHERE @Status IS NULL OR c.Status = @Status
    ORDER BY CASE WHEN c.Status = N'BelowMin' THEN 0 ELSE 1 END, c.MissingBase DESC, i.ItemCode;

    -- 2: the totals of the scope
    SELECT Items = COUNT(*), BelowMin = ISNULL(SUM(CASE WHEN c.Status = N'BelowMin' THEN 1 ELSE 0 END), 0)
    FROM #co c;

    -- 3: the scope
    SELECT BranchId = b.Id, BranchName = b.BranchName
    FROM (SELECT Id = @BranchId) s
    LEFT JOIN masterdata.Branches b ON b.Id = s.Id;
END

GO

