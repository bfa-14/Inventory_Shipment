-- WAREHOUSES ARE LEFT OUT unless asked (Stock Valuation's filter) or named by @IncludeId: every other picker gets
-- today's rows, and the name of an empty On the way warehouse still resolves through @IncludeId.
CREATE   PROCEDURE masterdata.usp_Warehouse_Lookup
    @ActiveOnly BIT = 1,
    @BranchId   INT = NULL,
    @IncludeId  INT = NULL,
    @IncludeTransit BIT = 0   -- (90) 1 = the branches' On the way warehouses too
AS
BEGIN
    SET NOCOUNT ON;
    SELECT w.Id, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName,
           w.IsMainWarehouse, w.IsActive, w.ParentId, w.[Level], w.AllowOutOfStockOverride,
           ChildCount = (SELECT COUNT(*) FROM masterdata.Warehouses c WHERE c.ParentId = w.Id),
           IsUsed     = masterdata.fn_Warehouse_IsUsed(w.Id),
           w.IsTransit                                                     -- (90)
    FROM masterdata.Warehouses w
    INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
    WHERE (@ActiveOnly = 0 OR w.IsActive = 1 OR w.Id = @IncludeId)
      AND (@BranchId IS NULL OR w.BranchId = @BranchId)
      AND (w.IsTransit = 0 OR @IncludeTransit = 1 OR w.Id = @IncludeId)   -- (90)
    ORDER BY w.IsMainWarehouse DESC, w.WarehouseName;
END

GO

