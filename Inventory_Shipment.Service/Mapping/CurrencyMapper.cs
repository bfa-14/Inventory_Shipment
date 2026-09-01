using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Service.Mapping;

public static class CurrencyMapper
{
    public static CurrencyDto ToDto(this Currency currency) => new()
    {
        Id = currency.Id,
        CurrencyCode = currency.CurrencyCode,
        CurrencyName = currency.CurrencyName,
        Symbol = currency.Symbol,
        DecimalPlaces = currency.DecimalPlaces,
        IsBaseCurrency = currency.IsBaseCurrency,
        IsActive = currency.IsActive,
        CreatedAtUtc = currency.CreatedAtUtc.AsUtc(),
        UpdatedAtUtc = currency.UpdatedAtUtc.AsUtc(),
        RowVersion = Convert.ToBase64String(currency.RowVersion)
    };

    public static CurrencyLookupDto ToDto(this CurrencyLookup currency) => new()
    {
        Id = currency.Id,
        CurrencyCode = currency.CurrencyCode,
        CurrencyName = currency.CurrencyName,
        Symbol = currency.Symbol,
        DecimalPlaces = currency.DecimalPlaces,
        IsBaseCurrency = currency.IsBaseCurrency,
        IsActive = currency.IsActive
    };
}
