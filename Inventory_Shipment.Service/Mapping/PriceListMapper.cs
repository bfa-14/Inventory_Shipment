using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Service.Mapping;

public static class PriceListMapper
{
    public static PriceListDto ToDto(this PriceList priceList) => new()
    {
        Id = priceList.Id,
        PriceListCode = priceList.PriceListCode,
        PriceListName = priceList.PriceListName,
        CurrencyId = priceList.CurrencyId,
        CurrencyCode = priceList.CurrencyCode,
        CurrencyName = priceList.CurrencyName,
        DecimalPlaces = priceList.DecimalPlaces,
        Description = priceList.Description,
        IsActive = priceList.IsActive,
        PriceCount = priceList.PriceCount,
        CreatedAtUtc = priceList.CreatedAtUtc.AsUtc(),
        UpdatedAtUtc = priceList.UpdatedAtUtc.AsUtc(),
        RowVersion = Convert.ToBase64String(priceList.RowVersion)
    };

    public static PriceListLookupDto ToDto(this PriceListLookup priceList) => new()
    {
        Id = priceList.Id,
        PriceListCode = priceList.PriceListCode,
        PriceListName = priceList.PriceListName,
        CurrencyId = priceList.CurrencyId,
        CurrencyCode = priceList.CurrencyCode,
        Symbol = priceList.Symbol,
        DecimalPlaces = priceList.DecimalPlaces,
        IsActive = priceList.IsActive
    };
}
