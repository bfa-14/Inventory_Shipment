using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Purchase;

/// <summary>
/// A landed cost adjustment is drafted, posted or cancelled — the same three states as a purchase
/// document, and for the same reason: posting moves value, so undoing it has to be its own act.
/// </summary>
public static class LandedCostAdjustmentStatus
{
    public const byte DraftCode = 1;
    public const byte PostedCode = 2;
    public const byte CancelledCode = 3;

    public const string Draft = "Draft";
    public const string Posted = "Posted";
    public const string Cancelled = "Cancelled";

    public static string From(byte code) => code switch
    {
        PostedCode => Posted,
        CancelledCode => Cancelled,
        _ => Draft,
    };

    public static byte? ToCode(string? status) => status switch
    {
        "1" or Draft => DraftCode,
        "2" or Posted => PostedCode,
        "3" or Cancelled => CancelledCode,
        _ => null,
    };
}

public sealed class LandedCostAdjustmentListDto
{
    public int Id { get; init; }
    public string DocumentNumber { get; init; } = string.Empty;
    public DateTime DocumentDate { get; init; }
    public int BranchId { get; init; }
    public string BranchName { get; init; } = string.Empty;
    public int SourceInvoiceId { get; init; }
    public string? SourceInvoiceNumber { get; init; }
    public int SupplierId { get; init; }
    public string SupplierName { get; init; } = string.Empty;
    public string Status { get; init; } = LandedCostAdjustmentStatus.Draft;

    /// <summary>The landed charges of the adjustment, in the base currency.</summary>
    public decimal TotalChargesBase { get; init; }

    /// <summary>The part that went back into stock value. Zero until posted.</summary>
    public decimal InventoryPortionBase { get; init; }

    /// <summary>The part that went straight to the period's cost of sales, because the goods had already gone.</summary>
    public decimal CogsPortionBase { get; init; }

    public DateTime? PostedAtUtc { get; init; }
    public string? PostedByName { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public byte[] RowVersion { get; init; } = [];

    public bool CanEdit => Status == LandedCostAdjustmentStatus.Draft;
    public bool CanPost => Status == LandedCostAdjustmentStatus.Draft;
    public bool CanCancel => Status == LandedCostAdjustmentStatus.Posted;
    public bool CanDelete => Status == LandedCostAdjustmentStatus.Draft;
}

/// <summary>
/// One invoice line as the adjustment touched it — the split, filled in at posting.
///
/// WHY A SPLIT AT ALL: a freight bill that arrives after the goods were received is partly about
/// stock still on the shelf (worth more now) and partly about goods already sold (whose cost of
/// sales was understated). The first raises the inventory value, the second lands in the period.
/// </summary>
public sealed class LandedCostAdjustmentLineDto
{
    public int Id { get; init; }
    public int PurchaseLineId { get; init; }

    /// <summary>The line's number on the INVOICE.</summary>
    public int LineNo { get; init; }

    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;

    /// <summary>The invoice line's quantity, in base units.</summary>
    public int ReceivedBase { get; init; }

    /// <summary>Received less what went back to the supplier.</summary>
    public int NetReceivedBase { get; init; }

    /// <summary>Of that, what is still in stock — the part that becomes inventory value rather than cost of sales.</summary>
    public int RemainingBase { get; init; }

    public decimal AllocatedBase { get; init; }

    /// <summary>What the adjustment adds to one base unit.</summary>
    public decimal ExtraPerBaseUnit { get; init; }

    public decimal InventoryPortionBase { get; init; }
    public decimal CogsPortionBase { get; init; }
    public decimal LandedCostBefore { get; init; }
    public decimal LandedCostAfter { get; init; }
}

public sealed class LandedCostAdjustmentDto
{
    public int Id { get; init; }
    public string DocumentNumber { get; init; } = string.Empty;
    public DateTime DocumentDate { get; init; }
    public int BranchId { get; init; }
    public string BranchName { get; init; } = string.Empty;
    public int SourceInvoiceId { get; init; }
    public string? SourceInvoiceNumber { get; init; }
    public int SupplierId { get; init; }
    public string SupplierCode { get; init; } = string.Empty;
    public string SupplierName { get; init; } = string.Empty;
    public int WarehouseId { get; init; }
    public string WarehouseName { get; init; } = string.Empty;
    public string? Notes { get; init; }
    public string Status { get; init; } = LandedCostAdjustmentStatus.Draft;

    public decimal TotalChargesBase { get; init; }
    public decimal InventoryPortionBase { get; init; }
    public decimal CogsPortionBase { get; init; }

    public DateTime? PostedAtUtc { get; init; }
    public int? PostedBy { get; init; }
    public string? PostedByName { get; init; }
    public DateTime? CancelledAtUtc { get; init; }
    public string? CancelReason { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public int? CreatedBy { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];

    public bool CanEdit => Status == LandedCostAdjustmentStatus.Draft;
    public bool CanPost => Status == LandedCostAdjustmentStatus.Draft;
    public bool CanCancel => Status == LandedCostAdjustmentStatus.Posted;
    public bool CanDelete => Status == LandedCostAdjustmentStatus.Draft;

    public IReadOnlyList<PurchaseChargeDto> Charges { get; init; } = [];

    /// <summary>The split over the invoice's lines. Empty while the adjustment is a draft.</summary>
    public IReadOnlyList<LandedCostAdjustmentLineDto> Lines { get; init; } = [];
}

public sealed class SaveLandedCostAdjustmentRequest
{
    /// <summary>The POSTED purchase invoice the charges belong to. It cannot be changed once the adjustment exists.</summary>
    [Range(1, int.MaxValue)]
    public int SourceInvoiceId { get; init; }

    [Required]
    public DateOnly DocumentDate { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    public IReadOnlyList<PurchaseChargeRequest> Charges { get; init; } = [];
    public IReadOnlyList<ManualAllocationRequest> ManualAllocations { get; init; } = [];
    public string? RowVersion { get; init; }
}

public sealed class LandedCostAdjustmentQuery
{
    /// <summary>Adjustment number, invoice number or supplier.</summary>
    public string? Search { get; init; }

    public int? SourceInvoiceId { get; init; }
    public int? BranchId { get; init; }

    /// <summary>Draft, Posted, Cancelled or the code 1–3.</summary>
    public string? Status { get; init; }

    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}

/// <summary>Posting and cancelling carry the version they were decided on; cancelling also says why.</summary>
public sealed class PostLandedCostAdjustmentRequest
{
    public string? RowVersion { get; init; }
}

public sealed class CancelLandedCostAdjustmentRequest
{
    [Required]
    [StringLength(300, MinimumLength = 1)]
    public string Reason { get; init; } = string.Empty;

    public string? RowVersion { get; init; }
}
