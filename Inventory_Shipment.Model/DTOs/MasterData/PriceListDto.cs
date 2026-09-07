namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Public view of a price list, including the currency columns the procedures join in.</summary>
public sealed class PriceListDto
{
    public int Id { get; init; }
    public string PriceListCode { get; init; } = string.Empty;
    public string PriceListName { get; init; } = string.Empty;
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public string CurrencyName { get; init; } = string.Empty;
    public byte DecimalPlaces { get; init; }
    public string? Description { get; init; }
    public bool IsActive { get; init; }

    /// <summary>Unit prices held by the list; non-zero locks the currency and blocks deletion.</summary>
    public int PriceCount { get; init; }

    public DateTime CreatedAtUtc { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }

    /// <summary>The row's ROWVERSION as Base64. Send it back on update to detect concurrent edits.</summary>
    public string RowVersion { get; init; } = string.Empty;
}

/// <summary>A price list as it appears in a dropdown, with the currency it prices in.</summary>
public sealed class PriceListLookupDto
{
    public int Id { get; init; }
    public string PriceListCode { get; init; } = string.Empty;
    public string PriceListName { get; init; } = string.Empty;
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public string? Symbol { get; init; }
    public byte DecimalPlaces { get; init; }
    public bool IsActive { get; init; }
}
