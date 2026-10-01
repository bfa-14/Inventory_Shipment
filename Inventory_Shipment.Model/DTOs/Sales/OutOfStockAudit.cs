namespace Inventory_Shipment.Model.DTOs.Sales;

/// <summary>
/// One out-of-stock sale the user confirmed: an item sold from a warehouse that held less than the
/// invoice took. Written when the invoice is posted and never changed, so a later cancellation of the
/// invoice shows in <see cref="InvoiceStatus"/> rather than erasing the row.
/// </summary>
public class OutOfStockAuditDto
{
    public long Id { get; init; }
    public int SalesDocumentId { get; init; }
    public string DocumentNumber { get; init; } = string.Empty;
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;

    /// <summary>Base units the invoice took from this warehouse (all its lines for the item).</summary>
    public int QuantitySold { get; init; }

    /// <summary>What the warehouse held before the invoice.</summary>
    public int StockBefore { get; init; }

    /// <summary>What it held right after; negative when the sale took it below zero.</summary>
    public int InventoryAfter { get; init; }

    public DateTime SoldAtUtc { get; init; }
    public int? UserId { get; init; }
    public string? UserName { get; init; }

    /// <summary>OutOfStockOverride.</summary>
    public string SaleStatus { get; init; } = string.Empty;

    /// <summary>Which level allowed the sale: Warehouse (its own override) or Global (the setting).</summary>
    public string PolicySource { get; init; } = string.Empty;

    /// <summary>The invoice as it stands now: Posted, or Cancelled if it was undone afterwards.</summary>
    public string InvoiceStatus { get; init; } = string.Empty;
}

/// <summary>Filters and paging for the out-of-stock audit log (bound from the query string). Newest first.</summary>
public sealed class OutOfStockAuditQuery
{
    /// <summary>Matches the item code, item name or invoice number (contains).</summary>
    public string? Search { get; init; }

    public int? WarehouseId { get; init; }

    /// <summary>The day the sale was confirmed, from (inclusive).</summary>
    public DateOnly? DateFrom { get; init; }

    /// <summary>The day the sale was confirmed, to (inclusive).</summary>
    public DateOnly? DateTo { get; init; }

    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 50;
}
