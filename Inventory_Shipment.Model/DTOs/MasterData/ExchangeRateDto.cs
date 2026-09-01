using Inventory_Shipment.Model.Enums;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>
/// Public view of an exchange rate, including the quoted currency it belongs to.
/// The rate means: 1 unit of the base currency = <see cref="Rate"/> units of this currency.
/// </summary>
public sealed class ExchangeRateDto
{
    public int Id { get; init; }
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public string CurrencyName { get; init; } = string.Empty;
    public string? Symbol { get; init; }
    public byte DecimalPlaces { get; init; }

    /// <summary>Official | NonOfficial | Market (serialized as a string).</summary>
    public RateType RateType { get; init; }

    /// <summary>The effective date, serialized as "yyyy-MM-dd".</summary>
    public DateOnly RateDate { get; init; }

    public decimal Rate { get; init; }
    public string? Notes { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }

    /// <summary>The row's ROWVERSION as Base64. Send it back on update to detect concurrent edits.</summary>
    public string RowVersion { get; init; } = string.Empty;
}
