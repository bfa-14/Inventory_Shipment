CREATE   PROCEDURE masterdata.usp_Warehouse_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT w.Id, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName, w.Address,
           w.IsMainWarehouse, w.IsActive, w.CreatedAtUtc, w.CreatedBy, w.UpdatedAtUtc, w.UpdatedBy, w.RowVersion,
           w.ParentId, w.[Level], w.AllowOutOfStockOverride,
           ParentCode = p.WarehouseCode,
           ParentName = p.WarehouseName,
           ChildCount = (SELECT COUNT(*) FROM masterdata.Warehouses c WHERE c.ParentId = w.Id)
    FROM masterdata.Warehouses w
    INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
    LEFT  JOIN masterdata.Warehouses p ON p.Id = w.ParentId
    WHERE w.Id = @Id;
END

GO

