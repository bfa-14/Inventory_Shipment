using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Service.Mapping;

public static class UnitTypeMapper
{
    public static UnitTypeDto ToDto(this UnitType unitType) => new()
    {
        Id = unitType.Id,
        UnitTypeName = unitType.UnitTypeName,
        IsActive = unitType.IsActive,
        CreatedAtUtc = unitType.CreatedAtUtc.AsUtc(),
        UpdatedAtUtc = unitType.UpdatedAtUtc.AsUtc(),
        RowVersion = Convert.ToBase64String(unitType.RowVersion)
    };

    public static UnitTypeLookupDto ToDto(this UnitTypeLookup unitType) => new()
    {
        Id = unitType.Id,
        UnitTypeName = unitType.UnitTypeName,
        IsActive = unitType.IsActive
    };
}
