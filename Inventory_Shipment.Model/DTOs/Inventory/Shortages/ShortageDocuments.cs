using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Inventory.Shortages;

/// <summary>
/// A shortage plan is a draft or it is posted; there is no cancelling. A draft is a working sheet —
/// edited, recalculated, deleted. A posted plan is a HISTORICAL SNAPSHOT: nothing on it is ever
/// computed again, and purchase orders are created from it.
/// </summary>
public static class ShortageDocumentStatus
{
    public const byte DraftCode = 1;
    public const byte PostedCode = 2;

    public const string Draft = "Draft";
    public const string Posted = "Posted";

    public static string From(byte code) => code == PostedCode ? Posted : Draft;

    public static byte? ToCode(string? status) => status switch
    {
        "1" or Draft => DraftCode,
        "2" or Posted => PostedCode,
        _ => null,
    };
}

/// <summary>
/// The figures every shortage row carries, live or saved. All quantities are BASE UNITS except
/// RequiredQty, which is in the item's purchase unit because that is what gets ordered.
///
///   Stock + Transit       = Current Inventory + Transit
///   Total Expected Stock  = Current Inventory + Transit + Outstanding Order
///   Expected Requirement  = Expected Monthly Sales × Lead Time (Month)
///   Shortage              = max(0, Requirement − Total Expected Stock)
///   Coverage (months)     = Total Expected Stock ÷ Expected Monthly Sales   (null when nothing sells)
///   Container Requirement = Required Qty × packing ÷ PC per Container       (null without a PC per container)
/// </summary>
public abstract class ShortageFiguresDto
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string BrandName { get; init; } = string.Empty;
    public string FamilyName { get; init; } = string.Empty;
    public bool IsBivac { get; init; }

    public int CurrentInventoryBase { get; init; }

    /// <summary>Marked as shipped on open purchase orders for the warehouse, not yet received.</summary>
    public int TransitBase { get; init; }

    /// <summary>Still to receive on open purchase orders, EXCLUDING what is already in transit.</summary>
    public int OutstandingOrderBase { get; init; }

    public int StockPlusTransitBase { get; init; }
    public int TotalExpectedStockBase { get; init; }

    /// <summary>Sales of the last "months of history" in the warehouse ÷ months. The computed value, never the override.</summary>
    public decimal ExpectedMonthlySalesBase { get; init; }

    public decimal LeadTimeMonths { get; init; }
    public decimal ExpectedRequirementBase { get; init; }
    public int ShortageBase { get; init; }
    public decimal? CoverageMonths { get; init; }

    public int PurchaseItemUnitId { get; init; }
    public string PurchaseUnitName { get; init; } = string.Empty;
    public int PurchasePackingFormula { get; init; }

    public int? PcPerContainer { get; init; }
    public decimal? ContainerRequirement { get; init; }

    public int? MinQuantity { get; init; }
    public int? MaxQuantity { get; init; }
    public decimal? LastCost { get; init; }
}

/// <summary>One LIVE row of inventory.usp_Shortage_Calculate — what "Load items" offers to a draft.</summary>
public sealed class ShortageLiveRowDto : ShortageFiguresDto
{
    public int SoldInPeriodBase { get; init; }
    public int MonthsOfHistory { get; init; }

    /// <summary>The shortage rounded up to whole purchase units — the default Required Qty of a new line.</summary>
    public int SuggestedRequiredQty { get; init; }

    public decimal? AverageCost { get; init; }
    public int? LeadTimeDays { get; init; }

    /// <summary>The default supplier, else the last one the item was bought from — what the supplier filter matches.</summary>
    public int? SupplierId { get; init; }

    public string? SupplierName { get; init; }
    public bool SupplierIsDefault { get; init; }
}

/// <summary>One SAVED line: the figures as they were when the plan was last saved or recalculated, plus what the planner typed.</summary>
public sealed class ShortageDocumentLineDto : ShortageFiguresDto
{
    public int Id { get; init; }

    /// <summary>LineNo on the DTO, LineNumber in SQL — LINENO is reserved in T-SQL.</summary>
    public int LineNo { get; init; }

    /// <summary>The planner's override of the computed monthly sales; null when the computed value stands.</summary>
    public decimal? ExpectedMonthlySalesManual { get; init; }

    /// <summary>The override when there is one, else the computed value — what every derived figure used.</summary>
    public decimal EffectiveMonthlySales { get; init; }

    /// <summary>Purchase units to order. Manual; defaults to the shortage rounded up to whole purchase units.</summary>
    public int RequiredQty { get; init; }

    public int RequiredBase { get; init; }
    public string? Notes { get; init; }
}

/// <summary>A purchase order created from a posted plan.</summary>
public sealed class ShortagePurchaseOrderDto
{
    public int Id { get; init; }
    public string? DocumentNumber { get; init; }
    public DateTime DocumentDate { get; init; }
    public string Status { get; init; } = string.Empty;
    public decimal TotalAmount { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public DateTime CreatedAtUtc { get; init; }
}

/// <summary>Created | Updated | Recalculated | Posted | POCreated.</summary>
public sealed class ShortageDocumentAuditDto
{
    public long Id { get; init; }
    public string Action { get; init; } = string.Empty;
    public string? Details { get; init; }
    public int? UserId { get; init; }
    public string? UserName { get; init; }
    public DateTime AtUtc { get; init; }
}

public sealed class ShortageDocumentListDto
{
    public int Id { get; init; }
    public string DocumentNumber { get; init; } = string.Empty;
    public string Description { get; init; } = string.Empty;
    public DateTime DocumentDate { get; init; }
    public int BranchId { get; init; }
    public string BranchName { get; init; } = string.Empty;
    public int WarehouseId { get; init; }
    public string WarehouseName { get; init; } = string.Empty;
    public int SupplierId { get; init; }
    public string SupplierCode { get; init; } = string.Empty;
    public string SupplierName { get; init; } = string.Empty;
    public decimal LeadTimeMonths { get; init; }
    public int MonthsOfHistory { get; init; }
    public string Status { get; init; } = ShortageDocumentStatus.Draft;
    public int TotalLines { get; init; }
    public int TotalShortageBase { get; init; }
    public int TotalRequiredBase { get; init; }
    public decimal TotalContainers { get; init; }
    public int ContainersRounded { get; init; }

    /// <summary>Purchase orders created from the plan, cancelled ones not counted.</summary>
    public int PurchaseOrders { get; init; }

    public DateTime? PostedAtUtc { get; init; }
    public string? PostedByName { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public int? CreatedBy { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];

    public bool CanEdit => Status == ShortageDocumentStatus.Draft;
    public bool CanDelete => Status == ShortageDocumentStatus.Draft;
}

public sealed class ShortageDocumentDto
{
    public int Id { get; init; }
    public string DocumentNumber { get; init; } = string.Empty;
    public string Description { get; init; } = string.Empty;
    public DateTime DocumentDate { get; init; }
    public int BranchId { get; init; }
    public string BranchCode { get; init; } = string.Empty;
    public string BranchName { get; init; } = string.Empty;
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public int SupplierId { get; init; }
    public string SupplierCode { get; init; } = string.Empty;
    public string SupplierName { get; init; } = string.Empty;
    public decimal LeadTimeMonths { get; init; }
    public int MonthsOfHistory { get; init; }
    public string? Notes { get; init; }
    public string Status { get; init; } = ShortageDocumentStatus.Draft;

    public int TotalLines { get; init; }
    public int TotalShortageBase { get; init; }
    public int TotalRequiredBase { get; init; }

    /// <summary>The sum of the lines' container requirements, e.g. 7.35.</summary>
    public decimal TotalContainers { get; init; }

    /// <summary>That sum rounded up: 8 containers have to be booked for 7.35.</summary>
    public int ContainersRounded { get; init; }

    /// <summary>How full the booked containers are, 7.35 ÷ 8 = 91.88 %. Null when no line has a container requirement.</summary>
    public decimal? ContainerUtilizationPct { get; init; }

    /// <summary>When the live figures were last taken — the last save or recalculation of the draft.</summary>
    public DateTime? CalculatedAtUtc { get; init; }

    public DateTime? PostedAtUtc { get; init; }
    public int? PostedBy { get; init; }
    public string? PostedByName { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public int? CreatedBy { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public int? UpdatedBy { get; init; }
    public string? UpdatedByName { get; init; }
    public byte[] RowVersion { get; init; } = [];

    /* What the DOCUMENT allows, from its status. Whether this user may is a permission, checked
       separately; both have to be true before a button is offered. */
    public bool CanEdit => Status == ShortageDocumentStatus.Draft;
    public bool CanRecalculate => Status == ShortageDocumentStatus.Draft;
    public bool CanPost => Status == ShortageDocumentStatus.Draft;
    public bool CanDelete => Status == ShortageDocumentStatus.Draft;

    /// <summary>Only a posted plan becomes purchase orders: an order has to point at figures that no longer move.</summary>
    public bool CanCreatePurchaseOrder => Status == ShortageDocumentStatus.Posted;

    public IReadOnlyList<ShortageDocumentLineDto> Lines { get; init; } = [];
    public IReadOnlyList<ShortagePurchaseOrderDto> PurchaseOrders { get; init; } = [];
    public IReadOnlyList<ShortageDocumentAuditDto> Audit { get; init; } = [];
}

/* ── requests ─────────────────────────────────────────────────────────────────────────────────── */

/// <summary>
/// One line of a plan as the planner sends it: the item and what was typed. THE FIGURES ARE NOT
/// SENT — the save procedure takes the live ones itself, so a plan cannot be saved with numbers
/// the page made up.
/// </summary>
public sealed class SaveShortageDocumentLineRequest
{
    /// <summary>Ignored: lines are numbered from their position in the list.</summary>
    public int LineNo { get; init; }

    [Range(1, int.MaxValue)]
    public int ItemId { get; init; }

    /// <summary>Purchase units to order. Null = the suggested quantity (the shortage rounded up).</summary>
    [Range(0, int.MaxValue)]
    public int? RequiredQty { get; init; }

    /// <summary>Overrides the computed monthly sales. Null = the computed value.</summary>
    [Range(0, 999999999)]
    public decimal? ExpectedMonthlySalesManual { get; init; }

    /// <summary>Null = the item's own PC per container.</summary>
    [Range(1, int.MaxValue)]
    public int? PcPerContainer { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }
}

public sealed class SaveShortageDocumentRequest
{
    [Required]
    [StringLength(200, MinimumLength = 1)]
    public string Description { get; init; } = string.Empty;

    [Required]
    public DateOnly DocumentDate { get; init; }

    /// <summary>The branch of the purchase order the plan becomes.</summary>
    [Range(1, int.MaxValue)]
    public int BranchId { get; init; }

    /// <summary>The warehouse the quantities are computed in.</summary>
    [Range(1, int.MaxValue)]
    public int WarehouseId { get; init; }

    [Range(1, int.MaxValue)]
    public int SupplierId { get; init; }

    /// <summary>"Lead Time (Month)" — decimals allowed, greater than zero.</summary>
    [Range(0.01, 9999.99)]
    public decimal LeadTimeMonths { get; init; } = 6;

    /// <summary>Months of sales history behind Expected Monthly Sales.</summary>
    [Range(1, 36)]
    public int MonthsOfHistory { get; init; } = 3;

    [StringLength(1000)]
    public string? Notes { get; init; }

    public IReadOnlyList<SaveShortageDocumentLineRequest> Lines { get; init; } = [];

    /// <summary>Base64 ROWVERSION read with the document (update only). Null skips the concurrency check.</summary>
    public string? RowVersion { get; init; }
}

/// <summary>Recalculate and Post carry nothing but the version they were decided on.</summary>
public sealed class ShortageDocumentActionRequest
{
    public string? RowVersion { get; init; }
}

public sealed class CreatePurchaseOrderFromShortageRequest
{
    /// <summary>Null = today.</summary>
    public DateOnly? DocumentDate { get; init; }

    public DateOnly? ExpectedDate { get; init; }
}

/* ── queries ──────────────────────────────────────────────────────────────────────────────────── */

public sealed class ShortageCalculateQuery
{
    [Range(1, int.MaxValue)]
    public int WarehouseId { get; init; }

    /// <summary>Items whose default (else last) supplier is this one.</summary>
    public int? SupplierId { get; init; }

    [Range(0.01, 9999.99)]
    public decimal LeadTimeMonths { get; init; } = 6;

    [Range(1, 36)]
    public int MonthsOfHistory { get; init; } = 3;

    /// <summary>The family and everything under it.</summary>
    public int? ItemFamilyId { get; init; }

    public int? BrandId { get; init; }
    public string? Search { get; init; }
    public bool OnlyShortages { get; init; } = true;
}

public sealed class ShortageDocumentQuery
{
    /// <summary>Shortage No. or description.</summary>
    public string? Search { get; init; }

    public int? WarehouseId { get; init; }
    public int? BranchId { get; init; }
    public int? SupplierId { get; init; }

    /// <summary>Draft, Posted or the code 1–2.</summary>
    public string? Status { get; init; }

    public int? CreatedBy { get; init; }
    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }
    public string SortBy { get; init; } = "DocumentDate";
    public string SortDir { get; init; } = "desc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}
