using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Service.Mapping;

public static class ItemMapper
{
    public static ItemListDto ToListDto(this Item item) => new()
    {
        Id = item.Id,
        ItemCode = item.ItemCode,
        ItemName = item.ItemName,
        BrandId = item.BrandId,
        BrandName = item.BrandName,
        Model = item.Model,
        ItemFamilyId = item.ItemFamilyId,
        FamilyCode = item.FamilyCode,
        FamilyName = item.FamilyName,
        CountryOfOrigin = item.CountryOfOrigin,
        DefaultWarehouseId = item.DefaultWarehouseId,
        WarehouseCode = item.WarehouseCode,
        WarehouseName = item.WarehouseName,
        BaseUnitName = item.BaseUnitName,
        BaseUnitSku = item.BaseUnitSku,
        OnHand = item.OnHand,
        AverageCost = item.AverageCost,
        LastCost = item.LastCost,
        FobCost = item.FobCost,
        InventoryValue = item.InventoryValue,
        DefaultSupplierId = item.DefaultSupplierId,
        DefaultSupplierName = item.DefaultSupplierName,
        IsBivac = item.IsBivac,
        IsActive = item.IsActive,
        CreatedAtUtc = item.CreatedAtUtc.AsUtc(),
        UpdatedAtUtc = item.UpdatedAtUtc.AsUtc(),
        RowVersion = Convert.ToBase64String(item.RowVersion)
    };

    /// <summary>The item as the details page reads it: the row plus its units and file metadata.</summary>
    public static ItemDetailsDto ToDetailsDto(
        this Item item, IReadOnlyList<ItemUnit> units, IReadOnlyList<ItemFile> files) => new()
    {
        Id = item.Id,
        ItemCode = item.ItemCode,
        ItemName = item.ItemName,
        BrandId = item.BrandId,
        BrandName = item.BrandName,
        Model = item.Model,
        ItemFamilyId = item.ItemFamilyId,
        FamilyCode = item.FamilyCode,
        FamilyName = item.FamilyName,
        CountryOfOrigin = item.CountryOfOrigin,
        DefaultWarehouseId = item.DefaultWarehouseId,
        WarehouseCode = item.WarehouseCode,
        WarehouseName = item.WarehouseName,
        Description = item.Description,
        WarrantyMonths = item.WarrantyMonths,
        MinQuantity = item.MinQuantity,
        MaxQuantity = item.MaxQuantity,
        IsBivac = item.IsBivac,
        IsActive = item.IsActive,
        OnHand = item.OnHand,
        LastCost = item.LastCost,
        AverageCost = item.AverageCost,
        LastPurchaseCost = item.LastPurchaseCost,
        DefaultSupplierId = item.DefaultSupplierId,
        DefaultSupplierCode = item.DefaultSupplierCode,
        DefaultSupplierName = item.DefaultSupplierName,
        LeadTimeDays = item.LeadTimeDays,
        PcPerContainer = item.PcPerContainer,
        WeightKg = item.WeightKg,
        VolumeCbm = item.VolumeCbm,
        FobCost = item.FobCost,
        InventoryValue = item.InventoryValue,
        LastSupplierId = item.LastSupplierId,
        LastSupplierName = item.LastSupplierName,
        LastPurchaseAtUtc = item.LastPurchaseAtUtc.AsUtc(),
        CreatedAtUtc = item.CreatedAtUtc.AsUtc(),
        CreatedByName = item.CreatedByName,
        UpdatedAtUtc = item.UpdatedAtUtc.AsUtc(),
        UpdatedByName = item.UpdatedByName,
        RowVersion = Convert.ToBase64String(item.RowVersion),
        Units = units.Select(u => u.ToDto()).ToList(),
        Files = files.Select(f => f.ToDto()).ToList()
    };

    public static ItemUnitDto ToDto(this ItemUnit unit) => new()
    {
        Id = unit.Id,
        ItemId = unit.ItemId,
        UnitTypeId = unit.UnitTypeId,
        UnitTypeName = unit.UnitTypeName,
        PackingFormula = unit.PackingFormula,
        SkuCode = unit.SkuCode,
        Barcode = unit.Barcode,
        IsSalesUnit = unit.IsSalesUnit,
        IsPurchaseUnit = unit.IsPurchaseUnit,
        IsBaseUnit = unit.IsBaseUnit,
        LengthCm = unit.LengthCm,
        WidthCm = unit.WidthCm,
        HeightCm = unit.HeightCm,
        WeightKg = unit.WeightKg,
        RowVersion = Convert.ToBase64String(unit.RowVersion)
    };

    public static ItemFileDto ToDto(this ItemFile file) => new()
    {
        Id = file.Id,
        ItemId = file.ItemId,
        FileName = file.FileName,
        ContentType = file.ContentType,
        SizeBytes = file.SizeBytes,
        IsItemImage = file.IsItemImage,
        CreatedAtUtc = file.CreatedAtUtc.AsUtc()
    };

    public static ItemLookupDto ToDto(this ItemLookup item) => new()
    {
        Id = item.Id,
        ItemCode = item.ItemCode,
        ItemName = item.ItemName,
        BaseUnitSku = item.BaseUnitSku,
        IsActive = item.IsActive
    };
}
