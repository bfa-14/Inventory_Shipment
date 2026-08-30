using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Service.Mapping;

public static class WarehouseMapper
{
    public static WarehouseDto ToDto(this Warehouse warehouse) => new()
    {
        Id = warehouse.Id,
        WarehouseCode = warehouse.WarehouseCode,
        WarehouseName = warehouse.WarehouseName,
        BranchId = warehouse.BranchId,
        BranchCode = warehouse.BranchCode,
        BranchName = warehouse.BranchName,
        Address = warehouse.Address,
        IsMainWarehouse = warehouse.IsMainWarehouse,
        IsActive = warehouse.IsActive,
        CreatedAtUtc = warehouse.CreatedAtUtc.AsUtc(),
        UpdatedAtUtc = warehouse.UpdatedAtUtc.AsUtc(),
        RowVersion = Convert.ToBase64String(warehouse.RowVersion)
    };

    public static WarehouseLookupDto ToLookupDto(this Warehouse warehouse) => new()
    {
        Id = warehouse.Id,
        WarehouseCode = warehouse.WarehouseCode,
        WarehouseName = warehouse.WarehouseName,
        BranchId = warehouse.BranchId,
        BranchCode = warehouse.BranchCode,
        BranchName = warehouse.BranchName,
        IsMainWarehouse = warehouse.IsMainWarehouse,
        IsActive = warehouse.IsActive
    };

    public static BranchLookupDto ToDto(this BranchLookup branch) => new()
    {
        Id = branch.Id,
        BranchCode = branch.BranchCode,
        BranchName = branch.BranchName,
        IsMainBranch = branch.IsMainBranch,
        IsActive = branch.IsActive
    };
}
