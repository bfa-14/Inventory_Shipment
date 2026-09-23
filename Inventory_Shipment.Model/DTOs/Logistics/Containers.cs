using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Logistics;

/// <summary>
/// The life of a container: Draft → Confirmed → In Transit → At Port → Cleared → Offloaded → Closed,
/// or Cancelled. 3 to 5 are DERIVED by the database from the route dates, 6 comes from the offload,
/// 7 and 8 are explicit — no request ever sets a status directly.
/// </summary>
public static class ContainerStatus
{
    public const byte Draft = 1;
    public const byte Confirmed = 2;
    public const byte InTransit = 3;
    public const byte AtPort = 4;
    public const byte Cleared = 5;
    public const byte Offloaded = 6;
    public const byte Closed = 7;
    public const byte Cancelled = 8;

    private static readonly string[] Names =
        ["Draft", "Confirmed", "In Transit", "At Port", "Cleared", "Offloaded", "Closed", "Cancelled"];

    public static string Name(byte status)
        => status is >= Draft and <= Cancelled ? Names[status - 1] : "Unknown";

    /// <summary>The code 1–8, or a name with or without the space ("InTransit", "in transit"); null when neither.</summary>
    public static byte? ToCode(string? status)
    {
        if (string.IsNullOrWhiteSpace(status))
        {
            return null;
        }

        if (byte.TryParse(status, out var code) && code is >= Draft and <= Cancelled)
        {
            return code;
        }

        var compact = status.Replace(" ", string.Empty, StringComparison.Ordinal);
        var index = Array.FindIndex(Names, n =>
            string.Equals(n.Replace(" ", string.Empty, StringComparison.Ordinal), compact, StringComparison.OrdinalIgnoreCase));
        return index >= 0 ? (byte)(index + 1) : null;
    }
}

/// <summary>The route events a user can record. "Offloaded" is written by the offload itself.</summary>
public static class ContainerEventTypes
{
    public const string Booked = "Booked";
    public const string Dispatched = "Dispatched";
    public const string PortArrival = "PortArrival";
    public const string CustomsRelease = "CustomsRelease";
    public const string BorderCrossing = "BorderCrossing";
    public const string Note = "Note";

    public static readonly string[] UserRecordable = [Booked, Dispatched, PortArrival, CustomsRelease, BorderCrossing, Note];

    public static string? Normalize(string? eventType)
        => UserRecordable.FirstOrDefault(t => string.Equals(t, eventType, StringComparison.OrdinalIgnoreCase));
}

public static class ShippingMethods
{
    public static readonly string[] All = ["Sea", "Air", "Road"];

    public static string? Normalize(string? method)
        => All.FirstOrDefault(m => string.Equals(m, method, StringComparison.OrdinalIgnoreCase));
}

/// <summary>
/// What a container's STATUS allows. Whether the caller may is a permission, checked separately;
/// both must hold before a button is offered. Shared by the list row and the details.
/// </summary>
public abstract record ContainerStatusFlags
{
    public byte Status { get; init; }
    public string StatusName => ContainerStatus.Name(Status);

    /// <summary>Everything before the goods arrive: the loading plan and the route can still change.</summary>
    public bool CanEdit => Status is >= ContainerStatus.Draft and <= ContainerStatus.Cleared;

    public bool CanConfirm => Status == ContainerStatus.Draft;
    public bool CanAddEvent => Status is >= ContainerStatus.Confirmed and <= ContainerStatus.Cleared;
    public bool CanOffload => Status is >= ContainerStatus.InTransit and <= ContainerStatus.Cleared;
    public bool CanCancelOffload => Status == ContainerStatus.Offloaded;
    public bool CanClose => Status == ContainerStatus.Offloaded;
    public bool CanCancel => Status is >= ContainerStatus.Draft and <= ContainerStatus.Cleared;
    public bool CanDelete => Status == ContainerStatus.Draft;
}

/// <summary>
/// One row of the container list. Supplier, invoice and item columns are SUMMARIES made by the
/// procedure ("Hero MotoCorp +1", "Mixed - 3 items"): a container may carry several of each.
/// </summary>
public record ContainerListDto : ContainerStatusFlags
{
    public int Id { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public string ContainerTypeCode { get; init; } = string.Empty;
    public string ContainerTypeName { get; init; } = string.Empty;
    public DateTime OrderDate { get; init; }

    /// <summary>yyyyMM, e.g. 202609 — what the Order Month filter sends back.</summary>
    public int OrderMonthKey { get; init; }

    /// <summary>"Sep-2026".</summary>
    public string OrderMonth { get; init; } = string.Empty;

    public int BranchId { get; init; }
    public string BranchCode { get; init; } = string.Empty;
    public string BranchName { get; init; } = string.Empty;
    public int? WarehouseId { get; init; }
    public string? WarehouseCode { get; init; }
    public string? WarehouseName { get; init; }
    public int SupplierCount { get; init; }
    public string? SupplierNames { get; init; }
    public int InvoiceCount { get; init; }
    public string? InvoiceNumbers { get; init; }
    public string? CommercialInvoiceNos { get; init; }
    public int ItemCount { get; init; }
    public string? ItemSummary { get; init; }
    public int TotalQtyBase { get; init; }
    public int TotalReceivedBase { get; init; }
    public decimal TotalOilQty { get; init; }
    public int? MaxUnits { get; init; }
    public decimal? UtilizationPct { get; init; }
    public string? BlNo { get; init; }
    public DateTime? BlDate { get; init; }
    public DateTime? DispatchDate { get; init; }
    public DateTime? Eta { get; init; }
    public DateTime? ActualPortArrival { get; init; }
    public DateTime? CustomsReleaseDate { get; init; }
    public DateTime? OffloadedDate { get; init; }
    public int? FreeDays { get; init; }

    /// <summary>Port arrival + free days. Demurrage starts the day after.</summary>
    public DateTime? LastFreeDay { get; init; }

    /// <summary>Days since the port arrival, up to the offload (or today).</summary>
    public int? DaysAtPort { get; init; }

    public string? CurrentLocation { get; init; }
    public string? StatusNote { get; init; }
    public string? PortOfLoadingName { get; init; }
    public string? PortOfDestinationName { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];

    /// <summary>
    /// The free time at the port is used up and the goods are still there. Only while the container
    /// is at port or cleared: once offloaded, the days are history, not an alarm.
    /// </summary>
    public bool IsFreeTimeOver
        => LastFreeDay is { } last
           && Status is ContainerStatus.AtPort or ContainerStatus.Cleared
           && DateTime.UtcNow.Date > last.Date;
}

/// <summary>A purchase invoice linked to the container, with how much of it is loaded here and elsewhere.</summary>
public sealed class ContainerInvoiceDto
{
    public int Id { get; init; }
    public int PurchaseDocumentId { get; init; }
    public string? DocumentNumber { get; init; }
    public DateTime DocumentDate { get; init; }

    /// <summary>1 Draft, 2 Posted, 3 Cancelled, 4 Closed — the purchase document's own status.</summary>
    public byte InvoiceStatus { get; init; }

    /// <summary>1 = stock on posting, 2 = stock on container offload.</summary>
    public byte ReceiptMode { get; init; }

    public int SupplierId { get; init; }
    public string SupplierCode { get; init; } = string.Empty;
    public string SupplierName { get; init; } = string.Empty;
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public string? CurrencySymbol { get; init; }
    public decimal ExchangeRate { get; init; }
    public string? SupplierReference { get; init; }
    public string? ExporterReference { get; init; }
    public string? CommercialInvoiceNo { get; init; }
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public int TotalQtyBase { get; init; }
    public int AllocatedHereBase { get; init; }
    public int AllocatedTotalBase { get; init; }
    public int RemainingBase { get; init; }
    public decimal TotalAmount { get; init; }
    public decimal TotalAmountBase { get; init; }
    public decimal TotalLandedCostBase { get; init; }
}

public sealed class ContainerLineDto
{
    public int Id { get; init; }
    public int LineNumber { get; init; }
    public int PurchaseDocumentId { get; init; }
    public string? InvoiceNumber { get; init; }
    public string? CommercialInvoiceNo { get; init; }
    public string SupplierName { get; init; } = string.Empty;
    public int PurchaseLineId { get; init; }
    public int InvoiceLineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string? Model { get; init; }
    public string? BrandName { get; init; }
    public int ItemUnitId { get; init; }
    public string UnitTypeName { get; init; } = string.Empty;
    public int PackingFormula { get; init; }

    /// <summary>In the purchase line's unit; <see cref="QuantityBase"/> is what capacity and stock count.</summary>
    public int Quantity { get; init; }

    public int QuantityBase { get; init; }
    public bool OilIncluded { get; init; }
    public decimal? OilQtyPerUnit { get; init; }
    public decimal TotalOilQty { get; init; }

    /// <summary>Null until the offload; then what actually entered stock (may be short).</summary>
    public int? ReceivedQuantityBase { get; init; }

    public string? VarianceReason { get; init; }
    public string? Notes { get; init; }
    public int InvoiceQtyBase { get; init; }
    public int AllocatedElsewhereBase { get; init; }

    /// <summary>The most this container may carry of the invoice line: the line less what other containers hold.</summary>
    public int AvailableBase { get; init; }

    public decimal? UnitCostBase { get; init; }
    public decimal? FobCostBase { get; init; }
    public int OnHandBase { get; init; }
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
}

public sealed class ContainerEventDto
{
    public long Id { get; init; }
    public string EventType { get; init; } = string.Empty;
    public DateTime EventDate { get; init; }
    public int? PortId { get; init; }
    public string? PortName { get; init; }
    public string? LocationText { get; init; }
    public string? Notes { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
}

public sealed class ContainerFileDto
{
    public int Id { get; init; }
    public int? AttachmentTypeId { get; init; }
    public string? Category { get; init; }
    public string? SubType { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public int SizeBytes { get; init; }
    public string? Note { get; init; }
    public DateTime? DocumentDate { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
}

public sealed class ContainerAuditDto
{
    public string Action { get; init; } = string.Empty;
    public string? Details { get; init; }
    public string? UserName { get; init; }
    public DateTime AtUtc { get; init; }
}

/// <summary>A supplier of the container — derived from the linked invoices, never entered.</summary>
public sealed class ContainerSupplierDto
{
    public int SupplierId { get; init; }
    public string SupplierCode { get; init; } = string.Empty;
    public string SupplierName { get; init; } = string.Empty;
}

/// <summary>
/// A container with everything the details page shows: the header (six sections of it), the linked
/// invoices, the loaded lines, the route, the files and the audit — the six result sets of
/// logistics.usp_Container_Get read in one round trip.
/// </summary>
public sealed record ContainerDto : ContainerStatusFlags
{
    public int Id { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public int ContainerTypeId { get; init; }
    public string ContainerTypeCode { get; init; } = string.Empty;
    public string ContainerTypeName { get; init; } = string.Empty;

    /// <summary>The type's own capacity, for "reset to the type" next to the editable <see cref="MaxUnits"/>.</summary>
    public int? TypeMaxUnits { get; init; }

    public decimal? MaxWeightKg { get; init; }
    public decimal? MaxVolumeCbm { get; init; }
    public string? SealNo { get; init; }
    public string? CustomsSealNo { get; init; }
    public string? Description { get; init; }

    public DateTime OrderDate { get; init; }
    public int OrderMonthKey { get; init; }
    public string OrderMonth { get; init; } = string.Empty;
    public string ShippingMethod { get; init; } = "Sea";
    public string? CountryOfOrigin { get; init; }
    public int? ForwarderId { get; init; }
    public string? ForwarderName { get; init; }
    public int? TransporterId { get; init; }
    public string? TransporterName { get; init; }

    public string? ShippingLine { get; init; }
    public string? VesselName { get; init; }
    public string? VoyageNo { get; init; }
    public string? BookingNo { get; init; }
    public int? PortOfLoadingId { get; init; }
    public string? PortOfLoadingName { get; init; }
    public string? PortOfLoadingCountry { get; init; }
    public int? PortOfDestinationId { get; init; }
    public string? PortOfDestinationName { get; init; }
    public string? PortOfDestinationCountry { get; init; }
    public int? FinalDestinationId { get; init; }
    public string? FinalDestinationName { get; init; }
    public DateTime? DispatchDate { get; init; }
    public DateTime? Eta { get; init; }
    public int? FreeDays { get; init; }
    public DateTime? LastFreeDay { get; init; }
    public decimal? GrossWeightKg { get; init; }
    public decimal? VolumeCbm { get; init; }
    public int? Packages { get; init; }

    public string? BlNo { get; init; }
    public DateTime? BlDate { get; init; }
    public string? BlNotes { get; init; }

    /* Capacity. A WARNING, NEVER A BLOCK: the numbers are here so the page can colour the bar and
       say "over capacity"; the save refuses only when the caller has not confirmed the override. */
    public int? MaxUnits { get; init; }
    public int TotalLines { get; init; }
    public int TotalAllocatedBase { get; init; }
    public int TotalReceivedBase { get; init; }
    public decimal TotalOilQty { get; init; }
    public decimal? UtilizationPct { get; init; }
    public int? RemainingCapacityBase { get; init; }
    public bool IsOverCapacity => MaxUnits is { } max && TotalAllocatedBase > max;

    public int BranchId { get; init; }
    public string BranchCode { get; init; } = string.Empty;
    public string BranchName { get; init; } = string.Empty;

    /// <summary>The offloading destination.</summary>
    public int? WarehouseId { get; init; }

    public string? WarehouseCode { get; init; }
    public string? WarehouseName { get; init; }
    public string? TruckNo { get; init; }
    public string? WaybillNo { get; init; }
    public string? DeclarationNo { get; init; }
    public string? FeriNo { get; init; }
    public DateTime? ActualPortArrival { get; init; }
    public DateTime? BorderCrossingDate { get; init; }
    public DateTime? CustomsReleaseDate { get; init; }
    public int? DaysAtPort { get; init; }
    public DateTime? OffloadedDate { get; init; }
    public DateTime? OffloadedAtUtc { get; init; }
    public string? OffloadedByName { get; init; }

    public string? StatusNote { get; init; }
    public string? CurrentLocation { get; init; }
    public string? Notes { get; init; }
    public DateTime? ConfirmedAtUtc { get; init; }
    public string? ConfirmedByName { get; init; }
    public DateTime? ClosedAtUtc { get; init; }
    public string? ClosedByName { get; init; }
    public DateTime? CancelledAtUtc { get; init; }
    public string? CancelledByName { get; init; }
    public string? CancelReason { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public string? UpdatedByName { get; init; }
    public byte[] RowVersion { get; init; } = [];

    /// <summary>Same rule as the list: at port or cleared, and the last free day is behind us.</summary>
    public bool IsFreeTimeOver
        => LastFreeDay is { } last
           && Status is ContainerStatus.AtPort or ContainerStatus.Cleared
           && DateTime.UtcNow.Date > last.Date;

    /// <summary>The distinct suppliers of the linked invoices, in the order the invoices come.</summary>
    public IReadOnlyList<ContainerSupplierDto> Suppliers
        => Invoices.DistinctBy(i => i.SupplierId)
            .Select(i => new ContainerSupplierDto { SupplierId = i.SupplierId, SupplierCode = i.SupplierCode, SupplierName = i.SupplierName })
            .ToList();

    public IReadOnlyList<ContainerInvoiceDto> Invoices { get; init; } = [];
    public IReadOnlyList<ContainerLineDto> Lines { get; init; } = [];

    /// <summary>Newest first.</summary>
    public IReadOnlyList<ContainerEventDto> Events { get; init; } = [];

    public IReadOnlyList<ContainerFileDto> Files { get; init; } = [];
    public IReadOnlyList<ContainerAuditDto> Audit { get; init; } = [];
}

/// <summary>A purchase invoice that still has something to load (logistics.usp_Container_AvailableInvoices).</summary>
public sealed class AvailableInvoiceDto
{
    public int Id { get; init; }
    public string? DocumentNumber { get; init; }
    public DateTime DocumentDate { get; init; }
    public byte Status { get; init; }
    public byte ReceiptMode { get; init; }
    public int SupplierId { get; init; }
    public string SupplierCode { get; init; } = string.Empty;
    public string SupplierName { get; init; } = string.Empty;
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public string? CurrencySymbol { get; init; }
    public string? SupplierReference { get; init; }
    public string? ExporterReference { get; init; }
    public string? CommercialInvoiceNo { get; init; }
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public int TotalQtyBase { get; init; }
    public int AllocatedBase { get; init; }

    /// <summary>What the container being edited already holds of it (0 for a new container).</summary>
    public int AllocatedHereBase { get; init; }

    public int RemainingBase { get; init; }
    public decimal TotalAmount { get; init; }
    public decimal TotalAmountBase { get; init; }
}

/// <summary>
/// One line of a purchase invoice as the loading grid needs it: how much of it other containers
/// hold, how much this one holds, and the most this one may take.
/// </summary>
public sealed class AvailableInvoiceLineDto
{
    public int PurchaseLineId { get; init; }
    public int PurchaseDocumentId { get; init; }
    public int LineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string? Model { get; init; }
    public int ItemUnitId { get; init; }
    public string UnitTypeName { get; init; } = string.Empty;
    public int PackingFormula { get; init; }
    public int Quantity { get; init; }
    public int QuantityBase { get; init; }

    /// <summary>Held by OTHER containers that are not cancelled.</summary>
    public int AllocatedElsewhereBase { get; init; }

    public int AllocatedHereBase { get; init; }

    /// <summary>QuantityBase − AllocatedElsewhereBase: the ceiling for this container, in base units.</summary>
    public int AvailableBase { get; init; }

    /// <summary>The item's oil per unit — the default when the line is loaded with oil.</summary>
    public decimal? OilQtyPerUnit { get; init; }
}

/* ── requests ──────────────────────────────────────────────────────────────────────────────── */

public sealed class SaveContainerLineRequest
{
    public int LineNumber { get; init; }

    [Range(1, int.MaxValue)]
    public int PurchaseLineId { get; init; }

    /// <summary>In the purchase line's unit.</summary>
    [Range(1, int.MaxValue)]
    public int Quantity { get; init; }

    public bool OilIncluded { get; init; }

    /// <summary>Null = the item's value (when oil is included).</summary>
    [Range(0, 9999999.99)]
    public decimal? OilQtyPerUnit { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }
}

public sealed class SaveContainerRequest
{
    [StringLength(20)]
    public string? ContainerNo { get; init; }

    [Range(1, int.MaxValue)]
    public int ContainerTypeId { get; init; }

    [StringLength(30)]
    public string? SealNo { get; init; }

    [StringLength(30)]
    public string? CustomsSealNo { get; init; }

    [StringLength(500)]
    public string? Description { get; init; }

    [Required]
    public DateOnly OrderDate { get; init; }

    /// <summary>Sea, Air or Road.</summary>
    [StringLength(10)]
    public string? ShippingMethod { get; init; }

    [StringLength(2, MinimumLength = 2)]
    public string? CountryOfOrigin { get; init; }

    public int? ForwarderId { get; init; }
    public int? TransporterId { get; init; }

    [StringLength(100)]
    public string? ShippingLine { get; init; }

    [StringLength(100)]
    public string? VesselName { get; init; }

    [StringLength(30)]
    public string? VoyageNo { get; init; }

    [StringLength(30)]
    public string? BookingNo { get; init; }

    public int? PortOfLoadingId { get; init; }
    public int? PortOfDestinationId { get; init; }
    public int? FinalDestinationId { get; init; }
    public DateOnly? DispatchDate { get; init; }
    public DateOnly? Eta { get; init; }

    [Range(0, 3650)]
    public int? FreeDays { get; init; }

    [Range(0, 999999999999.999)]
    public decimal? GrossWeightKg { get; init; }

    [Range(0, 999999999999.999)]
    public decimal? VolumeCbm { get; init; }

    [Range(0, int.MaxValue)]
    public int? Packages { get; init; }

    [StringLength(30)]
    public string? BlNo { get; init; }

    public DateOnly? BlDate { get; init; }

    [StringLength(500)]
    public string? BlNotes { get; init; }

    /// <summary>Null = the container type's capacity (or, on an update, the capacity already set).</summary>
    [Range(1, int.MaxValue)]
    public int? MaxUnits { get; init; }

    [Range(1, int.MaxValue)]
    public int BranchId { get; init; }

    /// <summary>The offloading destination.</summary>
    public int? WarehouseId { get; init; }

    [StringLength(30)]
    public string? TruckNo { get; init; }

    [StringLength(30)]
    public string? WaybillNo { get; init; }

    [StringLength(30)]
    public string? DeclarationNo { get; init; }

    [StringLength(30)]
    public string? FeriNo { get; init; }

    public DateOnly? ActualPortArrival { get; init; }
    public DateOnly? BorderCrossingDate { get; init; }
    public DateOnly? CustomsReleaseDate { get; init; }

    [StringLength(200)]
    public string? StatusNote { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    /// <summary>The purchase invoices linked. The invoice of every line is linked too, even if missing here.</summary>
    public IReadOnlyList<int> Invoices { get; init; } = [];

    public IReadOnlyList<SaveContainerLineRequest> Lines { get; init; } = [];

    /// <summary>The caller confirmed loading above capacity. Needs containers.overcapacity.</summary>
    public bool AllowOverCapacity { get; init; }

    public string? RowVersion { get; init; }
}

public sealed class OffloadLineRequest
{
    [Range(1, int.MaxValue)]
    public int LineId { get; init; }

    [Range(0, int.MaxValue)]
    public int ReceivedQuantityBase { get; init; }

    /// <summary>Required by the procedure when the received quantity differs from the loaded one.</summary>
    [StringLength(200)]
    public string? VarianceReason { get; init; }
}

/// <summary>The goods arrive. NO LINES = everything received as loaded.</summary>
public sealed class OffloadRequest
{
    public IReadOnlyList<OffloadLineRequest> Lines { get; init; } = [];

    /// <summary>Null = today.</summary>
    public DateOnly? OffloadedDate { get; init; }

    /// <summary>Null = the container's warehouse.</summary>
    public int? WarehouseId { get; init; }

    public string? RowVersion { get; init; }
}

public sealed class AddEventRequest
{
    /// <summary>Booked, Dispatched, PortArrival, CustomsRelease, BorderCrossing or Note.</summary>
    [Required]
    [StringLength(20)]
    public string EventType { get; init; } = string.Empty;

    [Required]
    public DateOnly EventDate { get; init; }

    public int? PortId { get; init; }

    /// <summary>Free text when the place is not a port of the master data.</summary>
    [StringLength(100)]
    public string? LocationText { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }
}

/// <summary>Cancelling a container, or reversing its offload: both need a reason.</summary>
public sealed class CancelRequest
{
    [Required]
    [StringLength(300, MinimumLength = 1)]
    public string Reason { get; init; } = string.Empty;

    public string? RowVersion { get; init; }
}

/// <summary>Confirm and Close carry nothing but the version the caller saw.</summary>
public sealed class ContainerActionRequest
{
    public string? RowVersion { get; init; }
}

public sealed class ContainerQuery
{
    /// <summary>Ref, container no., B/L, vessel, PI no., commercial invoice no. or supplier (contains).</summary>
    public string? Search { get; init; }

    public string? ContainerRef { get; init; }
    public string? ContainerNo { get; init; }
    public int? SupplierId { get; init; }
    public int? PurchaseDocumentId { get; init; }
    public string? CommercialInvoiceNo { get; init; }
    public int? ItemId { get; init; }
    public string? BlNo { get; init; }

    /// <summary>The code 1–8 or the name (Draft, Confirmed, InTransit / "In Transit", ...).</summary>
    public string? Status { get; init; }

    /// <summary>Port of loading, destination or final destination.</summary>
    public int? PortId { get; init; }

    public int? WarehouseId { get; init; }
    public int? BranchId { get; init; }

    /// <summary>yyyyMM, e.g. 202609.</summary>
    public int? OrderMonthKey { get; init; }

    /// <summary>Order date range.</summary>
    public DateOnly? DateFrom { get; init; }

    public DateOnly? DateTo { get; init; }
    public string SortBy { get; init; } = "OrderDate";
    public string SortDir { get; init; } = "desc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}

public sealed class AvailableInvoiceQuery
{
    /// <summary>PI no., commercial invoice no., supplier / exporter reference or supplier name.</summary>
    public string? Search { get; init; }

    public int? SupplierId { get; init; }

    /// <summary>The container being edited: what it already holds counts as available to it.</summary>
    public int? ContainerId { get; init; }

    [Range(1, 200)]
    public int Top { get; init; } = 50;
}
