namespace Inventory_Shipment.Model.Entities;

/// <summary>
/// A currency (table masterdata.Currencies). Exactly one active currency carries
/// <see cref="IsBaseCurrency"/>: amounts are stored and reported in it, and it never has
/// exchange rate rows because its rate is 1 by definition.
/// </summary>
public class Currency
{
    public int Id { get; set; }

    /// <summary>ISO 4217 code, exactly 3 letters, stored upper-case (USD, EUR, CDF...).</summary>
    public string CurrencyCode { get; set; } = string.Empty;

    public string CurrencyName { get; set; } = string.Empty;

    /// <summary>Display symbol such as $, € or FC. Optional.</summary>
    public string? Symbol { get; set; }

    /// <summary>Digits shown after the decimal separator (0-6); 0 for currencies without cents.</summary>
    public byte DecimalPlaces { get; set; } = 2;

    public bool IsBaseCurrency { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTime CreatedAtUtc { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? UpdatedAtUtc { get; set; }
    public int? UpdatedBy { get; set; }

    /// <summary>SQL Server ROWVERSION (8 bytes) used for optimistic concurrency.</summary>
    public byte[] RowVersion { get; set; } = [];
}

/// <summary>One row of masterdata.usp_Currency_Lookup - just enough to fill a Currency dropdown.</summary>
public sealed class CurrencyLookup
{
    public int Id { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public string CurrencyName { get; set; } = string.Empty;
    public string? Symbol { get; set; }
    public byte DecimalPlaces { get; set; }
    public bool IsBaseCurrency { get; set; }
    public bool IsActive { get; set; }
}
