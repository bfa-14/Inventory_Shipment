using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Service.Mapping;

public static class ItemFamilyMapper
{
    public static ItemFamilyDto ToDto(this ItemFamily family) => new()
    {
        Id = family.Id,
        ParentId = family.ParentId,
        FamilyCode = family.FamilyCode,
        FamilyName = family.FamilyName,
        Description = family.Description,
        Level = family.Level,
        IsActive = family.IsActive,
        ChildCount = family.ChildCount,
        CreatedAtUtc = family.CreatedAtUtc.AsUtc(),
        UpdatedAtUtc = family.UpdatedAtUtc.AsUtc(),
        RowVersion = Convert.ToBase64String(family.RowVersion)
    };

    public static ItemFamilyLookupDto ToDto(this ItemFamilyLookup family) => new()
    {
        Id = family.Id,
        ParentId = family.ParentId,
        FamilyCode = family.FamilyCode,
        FamilyName = family.FamilyName,
        Level = family.Level,
        IsActive = family.IsActive
    };
}
