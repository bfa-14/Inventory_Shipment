CREATE   PROCEDURE masterdata.usp_Warehouse_GetMain
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (1) w.Id, w.WarehouseCode, w.WarehouseName, w.BranchId, b.BranchCode, b.BranchName, w.Address,
           w.IsMainWarehouse, w.IsActive, w.CreatedAtUtc, w.CreatedBy, w.UpdatedAtUtc, w.UpdatedBy, w.RowVersion
    FROM masterdata.Warehouses w
    INNER JOIN masterdata.Branches b ON b.Id = w.BranchId
    WHERE w.IsMainWarehouse = 1 AND w.IsActive = 1;
END

GO

