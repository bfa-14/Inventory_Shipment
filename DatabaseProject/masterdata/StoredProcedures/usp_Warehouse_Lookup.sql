/* ================================================================== 7. Master data procedures re-created (4.3.6) */

/* (91) THE WAREHOUSES A DROPDOWN OFFERS (script 90's rows and columns), + why one counts as used: by stock or a
   document (IsUsedInTransactions), by stock levels (HasStockLevels). IsUsed = either, as fn_Warehouse_IsUsed says; each
   test is worked out once a row (the parent picker labels a warehouse that has levels and nothing else). */
-- Re-created (91) from the body of script 90: + IsUsedInTransactions and HasStockLevels (the two last columns), IsUsed
-- from them (same rows, same values).
-- Re-created (92) from the body of script 91: + @UserId (last) and the column CanUse (last): may the reader move
-- stock in it (worked out per request, never cached). Rows, order and every other column unchanged; without
-- @UserId every row but an On the way one has CanUse = 1.
CREATE   PROCEDURE masterdata.usp_Warehouse_Lookup
    @ActiveOnly BIT = 1,
    @BranchId   INT = NULL,
    @IncludeId  INT = NULL,
    @IncludeTransit BIT = 0,  -- (90) 1 = the branches' On the way warehouses too
    @UserId     INT = NULL    -- (92) the reader
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Unrestricted BIT = security.fn_User_IsUnrestricted(@UserId);          -- (92)
    DECLARE @Usable TABLE (WarehouseId INT NOT NULL PRIMARY KEY);
    IF @Unrestricted = 0 INSERT INTO @Usable (WarehouseId) SELECT WarehouseId FROM security.fn_User_Warehouses(@UserId);
    SELECT w.Id, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName,
           w.IsMainWarehouse, w.IsActive, w.ParentId, w.[Level], w.AllowOutOfStockOverride,
           ChildCount = (SELECT COUNT(*) FROM masterdata.Warehouses c WHERE c.ParentId = w.Id),
           IsUsed     = CAST(u.T | u.L AS BIT),                             -- (91) = fn_Warehouse_IsUsed, worked out once
           w.IsTransit,                                                    -- (90)
           IsUsedInTransactions = u.T,                                     -- (91) stock or a document names it
           HasStockLevels       = u.L,                                     -- (91) it has stock levels
           CanUse               = CAST(CASE WHEN w.IsTransit = 1 THEN 0
                                            WHEN @Unrestricted = 1 OR w.Id IN (SELECT WarehouseId FROM @Usable) THEN 1
                                            ELSE 0 END AS BIT)                 -- (92) the reader may move stock in it
    FROM masterdata.Warehouses w
    INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
    CROSS APPLY (SELECT T = masterdata.fn_Warehouse_IsUsedInTransactions(w.Id),
                        L = CAST(CASE WHEN EXISTS (SELECT 1 FROM inventory.ItemWarehouseLevels lv WHERE lv.WarehouseId = w.Id)
                                      THEN 1 ELSE 0 END AS BIT)) u                                       -- (91)
    WHERE (@ActiveOnly = 0 OR w.IsActive = 1 OR w.Id = @IncludeId)
      AND (@BranchId IS NULL OR w.BranchId = @BranchId)
      AND (w.IsTransit = 0 OR @IncludeTransit = 1 OR w.Id = @IncludeId)   -- (90)
    ORDER BY w.IsMainWarehouse DESC, w.WarehouseName;
END

GO

