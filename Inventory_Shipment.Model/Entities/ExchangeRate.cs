using Inventory_Shipment.Model.Enums;

namespace Inventory_Shipment.Model.Entities;

/// <summary>
/// One exchange rate (table masterdata.ExchangeRates): 1 unit of the BASE currency equals
/// <see cref="Rate"/> units of <see cref="CurrencyId"/> on <see cref="RateDate"/>. There is at most
/// one row per currency + rate type + date, and a rate stays in force until a newer date exists.
/// </summary>
public class ExchangeRate
{
    public int Id { get; set; }

    /// <summary>The quoted currency. Never the base currency.</summary>
    public int CurrencyId { get; set; }

    /// <summary>Code of the quoted currency. Read-only: it comes from the join, never from the caller.</summary>
    public string CurrencyCode { get; set; } = string.Empty;

    /// <summary>Name of the quoted currency. Read-only: it comes from the join, never from the caller.</summary>
    public string CurrencyName { get; set; } = string.Empty;

    /// <summary>Symbol of the quoted currency. Read-only: it comes from the join.</summary>
    public string? Symbol { get; set; }

    /// <summary>Decimal places of the quoted currency. Read-only: it comes from the join.</summary>
    public byte DecimalPlaces { get; set; }

    public RateType RateType { get; set; }

    /// <summary>
    /// The effective date (a SQL DATE - the time part is always midnight). Kept as DateTime because
    /// that is what Dapper / SqlClient map a DATE column to; the DTO exposes it as a DateOnly.
    /// </summary>
    public DateTime RateDate { get; set; }

    public decimal Rate { get; set; }

    /// <summary>Free text, e.g. the market source the rate was taken from.</summary>
    public string? Notes { get; set; }

    public DateTime CreatedAtUtc { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? UpdatedAtUtc { get; set; }
    public int? UpdatedBy { get; set; }

    /// <summary>SQL Server ROWVERSION (8 bytes) used for optimistic concurrency.</summary>
    public byte[] RowVersion { get; set; } = [];
}
