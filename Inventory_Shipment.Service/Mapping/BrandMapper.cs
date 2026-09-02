using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Service.Mapping;

public static class BrandMapper
{
    public static BrandDto ToDto(this Brand brand) => new()
    {
        Id = brand.Id,
        BrandCode = brand.BrandCode,
        BrandName = brand.BrandName,
        Description = brand.Description,
        IsActive = brand.IsActive,
        CreatedAtUtc = brand.CreatedAtUtc.AsUtc(),
        UpdatedAtUtc = brand.UpdatedAtUtc.AsUtc(),
        RowVersion = Convert.ToBase64String(brand.RowVersion)
    };

    public static BrandLookupDto ToDto(this BrandLookup brand) => new()
    {
        Id = brand.Id,
        BrandCode = brand.BrandCode,
        BrandName = brand.BrandName,
        IsActive = brand.IsActive
    };
}
