namespace Inventory_Shipment.Model.Entities;

/// <summary>
/// A selling price list (table masterdata.PriceLists). Flat master data - code, name and the currency
/// every price in the list is expressed in. The currency is locked once the list contains prices.
/// </summary>
public class PriceList
{
    public int Id { get; set; }
    public string PriceListCode { get; set; } = string.Empty;
    public string PriceListName { get; set; } = string.Empty;
    public int CurrencyId { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTime CreatedAtUtc { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? UpdatedAtUtc { get; set; }
    public int? UpdatedBy { get; set; }

    /// <summary>SQL Server ROWVERSION (8 bytes) used for optimistic concurrency.</summary>
    public byte[] RowVersion { get; set; } = [];

    // ----- read-only columns the procedures join in -----

    public string CurrencyCode { get; set; } = string.Empty;
    public string CurrencyName { get; set; } = string.Empty;
    public byte DecimalPlaces { get; set; }

    /// <summary>How many unit prices the list holds. Non-zero means the currency can no longer change.</summary>
    public int PriceCount { get; set; }
}

/// <summary>One row of masterdata.usp_PriceList_Lookup - just enough to fill a Price List dropdown.</summary>
public sealed class PriceListLookup
{
    public int Id { get; set; }
    public string PriceListCode { get; set; } = string.Empty;
    public string PriceListName { get; set; } = string.Empty;
    public int CurrencyId { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public string? Symbol { get; set; }
    public byte DecimalPlaces { get; set; }
    public bool IsActive { get; set; }
}
