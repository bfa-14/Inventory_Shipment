using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Purchase;

/// <summary>
/// One item in one warehouse, as inventory.usp_Shortage_Report evaluates it.
///
/// AVAILABLE = ON HAND + INCOMING, and it is Available that is compared with the minimum: an item
/// already on a posted purchase order is on its way, and ordering it again is the mistake this report
/// exists to prevent. Suggested is what brings the warehouse back up to its maximum, in the purchase
/// unit, rounded up to whole packs.
/// </summary>
public sealed class ShortageRowDto
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public int BrandId { get; init; }
    public string BrandName { get; init; } = string.Empty;
    public int ItemFamilyId { get; init; }
    public string FamilyName { get; init; } = string.Empty;
    public bool IsBivac { get; init; }
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public int BranchId { get; init; }
    public string BranchName { get; init; } = string.Empty;
    public decimal OnHandBase { get; init; }
    public decimal IncomingBase { get; init; }
    public decimal AvailableBase { get; init; }
    public int MinQuantity { get; init; }
    public int? MaxQuantity { get; init; }
    public decimal ShortageBase { get; init; }
    public decimal SuggestedBase { get; init; }
    public int? PurchaseItemUnitId { get; init; }
    public string? PurchaseUnitName { get; init; }
    public int? PurchasePackingFormula { get; init; }

    /// <summary>Whole purchase units that bring Available up to the maximum (0 when nothing is short).</summary>
    public int SuggestedQty { get; init; }

    public decimal AvgDailySalesBase { get; init; }

    /// <summary>Days the stock on hand lasts at the average sales rate; null when nothing was sold.</summary>
    public decimal? DaysOfCover { get; init; }

    /// <summary>The default supplier, else the last one the item was bought from.</summary>
    public int? SupplierId { get; init; }

    public string? SupplierName { get; init; }
    public bool SupplierIsDefault { get; init; }
    public decimal? LastCost { get; init; }
    public decimal? AverageCost { get; init; }
    public int? LeadTimeDays { get; init; }
    public DateTime? LastPurchaseAtUtc { get; init; }
}

public sealed class ShortageQuery
{
    public int? BranchId { get; init; }
    public int? WarehouseId { get; init; }
    public int? ItemFamilyId { get; init; }
    public int? BrandId { get; init; }
    public int? SupplierId { get; init; }
    public string? Search { get; init; }

    /// <summary>True = rows where Available is below the minimum; false = every evaluated item and warehouse.</summary>
    public bool OnlyShortages { get; init; } = true;

    /// <summary>The window the average daily sales is taken over: 30, 60 or 90 days.</summary>
    [Range(1, 365)]
    public int DaysForAverage { get; init; } = 30;
}

/// <summary>One line the user decided to order from the shortage report.</summary>
public sealed class ShortageOrderLineRequest
{
    [Range(1, int.MaxValue)]
    public int ItemId { get; init; }

    [Range(1, int.MaxValue)]
    public int WarehouseId { get; init; }

    [Range(1, int.MaxValue)]
    public int SupplierId { get; init; }

    /// <summary>The unit ordered in — the item's purchase unit from the report, unless the user chose another.</summary>
    [Range(1, int.MaxValue)]
    public int ItemUnitId { get; init; }

    [Range(1, int.MaxValue)]
    public int Quantity { get; init; }

    /// <summary>Null = the item's last cost, converted to the order's currency.</summary>
    [Range(0, double.MaxValue)]
    public decimal? UnitPrice { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }
}

public sealed class CreatePurchaseOrdersFromShortagesRequest
{
    /// <summary>Null = today.</summary>
    public DateOnly? DocumentDate { get; init; }

    public DateOnly? ExpectedDate { get; init; }

    [Range(1, 3)]
    public byte RateType { get; init; } = 1;

    [StringLength(1000)]
    public string? Notes { get; init; }

    [MinLength(1)]
    public IReadOnlyList<ShortageOrderLineRequest> Lines { get; init; } = [];
}

public sealed class CreatedPurchaseOrderDto
{
    public int Id { get; init; }
    public string? DocumentNumber { get; init; }
    public int SupplierId { get; init; }
    public string SupplierName { get; init; } = string.Empty;
    public int WarehouseId { get; init; }
    public string WarehouseName { get; init; } = string.Empty;
    public int BranchId { get; init; }
    public string BranchName { get; init; } = string.Empty;
    public string CurrencyCode { get; init; } = string.Empty;
    public decimal ExchangeRate { get; init; }
    public int LineCount { get; init; }
    public decimal TotalAmount { get; init; }
    public string Status { get; init; } = PurchaseDocumentStatus.Draft;
}

public sealed class ShortageOrderFailure
{
    public int SupplierId { get; init; }
    public int WarehouseId { get; init; }
    public string Code { get; init; } = string.Empty;
    public string Message { get; init; } = string.Empty;
}

public sealed class CreatePurchaseOrdersResult
{
    public IReadOnlyList<CreatedPurchaseOrderDto> Orders { get; init; } = [];
    public int Created { get; init; }
    public IReadOnlyList<ShortageOrderFailure> Failed { get; init; } = [];
}
