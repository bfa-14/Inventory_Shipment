using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Service.Mapping;

public static class ExchangeRateMapper
{
    public static ExchangeRateDto ToDto(this ExchangeRate rate) => new()
    {
        Id = rate.Id,
        CurrencyId = rate.CurrencyId,
        CurrencyCode = rate.CurrencyCode,
        CurrencyName = rate.CurrencyName,
        Symbol = rate.Symbol,
        DecimalPlaces = rate.DecimalPlaces,
        RateType = rate.RateType,
        // The column is a SQL DATE; the entity carries it as a DateTime at midnight.
        RateDate = DateOnly.FromDateTime(rate.RateDate),
        Rate = rate.Rate,
        Notes = rate.Notes,
        CreatedAtUtc = rate.CreatedAtUtc.AsUtc(),
        UpdatedAtUtc = rate.UpdatedAtUtc.AsUtc(),
        RowVersion = Convert.ToBase64String(rate.RowVersion)
    };
}
