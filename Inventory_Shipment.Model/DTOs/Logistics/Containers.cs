using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Logistics;

/// <summary>
/// The life of a container: Draft → Confirmed → In Transit → At Port → Cleared → Offloaded → Closed,
/// or Cancelled. 3 to 5 are DERIVED by the database from the movements (or the dates typed on the
/// header while it has none), 6 comes from the offload, 7 and 8 are explicit — no request ever sets
/// a status directly.
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

public static class ShippingMethods
{
    public static readonly string[] All = ["Sea", "Air", "Road"];

    public static string? Normalize(string? method)
        => All.FirstOrDefault(m => string.Equals(m, method, StringComparison.OrdinalIgnoreCase));
}

/// <summary>Where a container line's FOB per unit comes from, in order of authority.</summary>
public static class FobSources
{
    /// <summary>Frozen by the offload.</summary>
    public const string Offload = "Offload";

    /// <summary>The invoice lines on the container line (posted or draft).</summary>
    public const string Invoice = "Invoice";

    /// <summary>The purchase order price: nothing invoiced yet.</summary>
    public const string Order = "Order";
}

/// <summary>
/// What a container's STATUS allows. Whether the caller may is a permission, checked separately;
/// both must hold before a button is offered. Shared by the list row and the details.
/// </summary>
public abstract record ContainerStatusFlags
{
    public byte Status { get; init; }
    public string StatusName => ContainerStatus.Name(Status);

    /// <summary>Everything before the goods arrive: the loading plan and the header can still change.</summary>
    public bool CanEdit => Status is >= ContainerStatus.Draft and <= ContainerStatus.Cleared;

    public bool CanConfirm => Status == ContainerStatus.Draft;

    /// <summary>The offload needs every line covered by POSTED invoices; the procedure says so too (69016).</summary>
    public bool CanOffload => Status is >= ContainerStatus.Confirmed and <= ContainerStatus.Cleared && FullyInvoiced;

    public bool CanCancelOffload => Status == ContainerStatus.Offloaded;
    public bool CanClose => Status == ContainerStatus.Offloaded;

    /// <summary>A closed container opens again as offloaded — a late charge arrived.</summary>
    public bool CanReopen => Status == ContainerStatus.Closed;

    public bool CanCancel => Status is >= ContainerStatus.Draft and <= ContainerStatus.Cleared;
    public bool CanDelete => Status == ContainerStatus.Draft;

    /// <summary>Protected, so it stays out of the JSON: each shape says it with its own column.</summary>
    protected abstract bool FullyInvoiced { get; }
}

/// <summary>Invoicing of a container by posted invoices, as the list shows it.</summary>
public static class ContainerInvoicingStatus
{
    public const int None = 0;
    public const int Partly = 1;
    public const int Fully = 2;
}

/// <summary>
/// One row of the container list. Order, supplier, invoice and item columns are SUMMARIES made by
/// the procedure ("PO-BR-002-000038 +1", "Mixed - 3 items"): a container may carry several of each.
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

    /// <summary>The order the container was created from; lines of other orders may have been added.</summary>
    public int? PurchaseOrderId { get; init; }

    public string? PurchaseOrderNumber { get; init; }
    public int OrderCount { get; init; }
    public string? OrderNumbers { get; init; }
    public int SupplierCount { get; init; }
    public string? SupplierNames { get; init; }
    public int InvoiceCount { get; init; }
    public string? InvoiceNumbers { get; init; }
    public string? CommercialInvoiceNos { get; init; }
    public string? ExporterReferences { get; init; }
    public int ItemCount { get; init; }
    public string? ItemSummary { get; init; }
    public int TotalQtyBase { get; init; }

    /// <summary>Covered by POSTED invoices.</summary>
    public int InvoicedQtyBase { get; init; }

    /// <summary>0 none, 1 partly, 2 fully invoiced — by posted invoices (see <see cref="ContainerInvoicingStatus"/>).</summary>
    public int InvoicingStatus { get; init; }

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

    /// <summary>The movement in progress, else the last completed one.</summary>
    public int? CurrentMovementId { get; init; }

    public string? CurrentMovementNo { get; init; }
    public byte? CurrentMovementStatus { get; init; }
    public decimal ChargesPostedBase { get; init; }
    public decimal ChargesDraftBase { get; init; }
    public int AttachmentCount { get; init; }
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

    protected override bool FullyInvoiced => InvoicingStatus == ContainerInvoicingStatus.Fully;
}

/// <summary>
/// One loaded line (result set 2 of usp_Container_Get): an ORDER line, the quantity in base units,
/// how far it is invoiced, and its cost — FOB per unit, the charges it took and the landed cost.
/// </summary>
public sealed class ContainerLineDto
{
    public int Id { get; init; }
    public int ContainerId { get; init; }
    public int LineNumber { get; init; }
    public int PurchaseOrderId { get; init; }
    public string? PurchaseOrderNumber { get; init; }
    public int SupplierId { get; init; }
    public string SupplierCode { get; init; } = string.Empty;
    public string SupplierName { get; init; } = string.Empty;
    public int PoLineId { get; init; }
    public int PoLineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string? Model { get; init; }
    public string? BrandName { get; init; }

    /// <summary>Always the item's base unit: containers count pieces.</summary>
    public int ItemUnitId { get; init; }

    public string UnitTypeName { get; init; } = string.Empty;
    public int PackingFormula { get; init; }

    /// <summary>The unit the order line was typed in, for reference.</summary>
    public string PoUnitTypeName { get; init; } = string.Empty;

    public int PoPackingFormula { get; init; }
    public int Quantity { get; init; }
    public int QuantityBase { get; init; }
    public bool OilIncluded { get; init; }
    public decimal? OilQtyPerUnit { get; init; }
    public decimal TotalOilQty { get; init; }

    /// <summary>The order line's quantity, and what other containers (not cancelled) hold of it.</summary>
    public int OrderedBase { get; init; }

    public int LoadedElsewhereBase { get; init; }
    public int InvoicedPostedBase { get; init; }
    public int InvoicedDraftBase { get; init; }

    /// <summary>Loaded − invoiced (posted and draft): what an invoice from this container may still take.</summary>
    public int AvailableToInvoiceBase { get; init; }

    /// <summary>"PINV-…-000024, PINV-…-000025".</summary>
    public string? InvoiceNumbers { get; init; }

    /// <summary>Null until the offload; then what actually entered stock (may be short).</summary>
    public int? ReceivedQuantityBase { get; init; }

    public string? VarianceReason { get; init; }
    public string? Notes { get; init; }

    /// <summary>After the offload the frozen value, else the invoices, else the order price (see <see cref="FobSource"/>).</summary>
    public decimal? UnitFobBase { get; init; }

    /// <summary>Order, Invoice or Offload.</summary>
    public string FobSource { get; init; } = FobSources.Order;

    public decimal? FobCostBase { get; init; }

    /// <summary>The POSTED charges this line took, in the base currency.</summary>
    public decimal ChargesBase { get; init; }

    public decimal DraftChargesBase { get; init; }
    public decimal? ChargesPerUnitBase { get; init; }

    /// <summary>FOB + charges per unit: final once offloaded (<see cref="IsLandedFinal"/>), an estimate before.</summary>
    public decimal? LandedCostBase { get; init; }

    public bool IsLandedFinal { get; init; }
    public decimal? WeightKg { get; init; }
    public decimal? VolumeCbm { get; init; }
}

/// <summary>A purchase invoice covering lines of the container (set 3), with its part in this container.</summary>
public sealed class ContainerInvoiceDto
{
    public int PurchaseDocumentId { get; init; }
    public string? DocumentNumber { get; init; }
    public DateTime DocumentDate { get; init; }

    /// <summary>1 Draft, 2 Posted, 3 Cancelled, 4 Closed — the purchase document's own status.</summary>
    public byte InvoiceStatus { get; init; }

    /// <summary>1 = stock on posting, 2 = stock on container offload.</summary>
    public byte ReceiptMode { get; init; }

    public int? PurchaseOrderId { get; init; }
    public string? PurchaseOrderNumber { get; init; }
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
    public int QtyInContainerBase { get; init; }
    public decimal AmountInContainer { get; init; }
    public decimal AmountInContainerBase { get; init; }
    public decimal TotalAmount { get; init; }
    public decimal TotalAmountBase { get; init; }
}

/// <summary>A movement the container travels with (set 4) — one leg of its route, oldest first.</summary>
public sealed class ContainerMovementDto
{
    public int MovementId { get; init; }
    public string MovementNo { get; init; } = string.Empty;
    public int MovementTypeId { get; init; }
    public string TypeCode { get; init; } = string.Empty;
    public string TypeName { get; init; } = string.Empty;

    /// <summary>Origin, Sea, Transit, Port, Border, Customs or Delivery.</summary>
    public string Stage { get; init; } = string.Empty;

    public int FromPlaceId { get; init; }
    public string FromCode { get; init; } = string.Empty;
    public string FromName { get; init; } = string.Empty;
    public string? FromCountry { get; init; }
    public string FromKind { get; init; } = string.Empty;
    public int ToPlaceId { get; init; }
    public string ToCode { get; init; } = string.Empty;
    public string ToName { get; init; } = string.Empty;
    public string? ToCountry { get; init; }
    public string ToKind { get; init; } = string.Empty;
    public DateTime? PlannedDate { get; init; }
    public DateTime? StartDate { get; init; }
    public DateTime? Eta { get; init; }
    public DateTime? EndDate { get; init; }

    /// <summary>1 Planned, 2 In progress, 3 Completed, 4 Cancelled.</summary>
    public byte Status { get; init; }

    public int? CarrierPartyId { get; init; }
    public string? CarrierName { get; init; }
    public string? VehicleOrVessel { get; init; }
    public string? VoyageNo { get; init; }
    public string? Reference { get; init; }
    public string? Notes { get; init; }
    public int ContainerCount { get; init; }

    /// <summary>Posted charges of THIS container linked to the movement.</summary>
    public decimal? ChargesBase { get; init; }

    public int AttachmentCount { get; init; }
}

/// <summary>A charge on the container (set 5). One charge typed for several containers is one row per container, same GroupId.</summary>
public sealed class ContainerChargeRowDto
{
    public int Id { get; init; }
    public int ContainerId { get; init; }
    public int? MovementId { get; init; }
    public string? MovementNo { get; init; }
    public Guid? GroupId { get; init; }
    public int GroupSize { get; init; }
    public int ChargeTypeId { get; init; }
    public string ChargeCode { get; init; } = string.Empty;
    public string ChargeName { get; init; } = string.Empty;
    public string? Description { get; init; }
    public int? ProviderPartyId { get; init; }
    public string? ProviderName { get; init; }
    public string? Reference { get; init; }
    public DateTime ChargeDate { get; init; }
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public byte RateType { get; init; }
    public decimal ExchangeRate { get; init; }
    public decimal Amount { get; init; }
    public decimal AmountBase { get; init; }

    /// <summary>Value, Quantity, Weight, Volume or Manual.</summary>
    public string AllocationMethod { get; init; } = string.Empty;

    public bool IncludeInLandedCost { get; init; }

    /// <summary>1 Draft, 2 Posted, 3 Cancelled.</summary>
    public byte Status { get; init; }

    /// <summary>Posted before the offload: it is in the landed cost the stock entered at.</summary>
    public bool AppliedAtOffload { get; init; }

    /// <summary>Posted (or cancelled) after the offload: written as a cost adjustment.</summary>
    public bool AdjustedAfterOffload { get; init; }

    public decimal? AllocatedBase { get; init; }
    public int AttachmentCount { get; init; }
    public string? Notes { get; init; }
    public DateTime? PostedAtUtc { get; init; }
    public string? PostedByName { get; init; }
    public DateTime? CancelledAtUtc { get; init; }
    public string? CancelReason { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

/// <summary>How a charge is divided over the container lines (set 6): the real cost of each item.</summary>
public sealed class ContainerChargeAllocationDto
{
    public int ChargeId { get; init; }
    public int ContainerLineId { get; init; }
    public int LineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;

    /// <summary>The value, quantity, weight or volume the share was computed from; null for manual shares.</summary>
    public decimal? Basis { get; init; }

    public decimal AmountBase { get; init; }
    public bool IsManual { get; init; }
    public decimal? PerUnitBase { get; init; }
}

/// <summary>A document attached to the container (set 7): general, or linked to a movement and / or a charge.</summary>
public sealed class ContainerAttachmentDto
{
    public int Id { get; init; }
    public int ContainerId { get; init; }
    public int? MovementId { get; init; }
    public string? MovementNo { get; init; }
    public int? ChargeId { get; init; }
    public int? AttachmentTypeId { get; init; }
    public string? Category { get; init; }
    public string? SubType { get; init; }

    /// <summary>The stored file; the same id on every container the upload went to.</summary>
    public int FileId { get; init; }

    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public int SizeBytes { get; init; }
    public string? Note { get; init; }
    public DateTime? DocumentDate { get; init; }
    public Guid? GroupId { get; init; }

    /// <summary>How many OTHER containers hold the same file.</summary>
    public int SharedWith { get; init; }

    public DateTime CreatedAtUtc { get; init; }
    public int? CreatedBy { get; init; }
    public string? CreatedByName { get; init; }
}

public sealed class ContainerAuditDto
{
    public long Id { get; init; }
    public string Action { get; init; } = string.Empty;
    public string? Details { get; init; }
    public int? UserId { get; init; }
    public string? UserName { get; init; }
    public DateTime AtUtc { get; init; }
}

/// <summary>A supplier of the container — derived from the order lines loaded, never entered.</summary>
public sealed class ContainerSupplierDto
{
    public int SupplierId { get; init; }
    public string SupplierCode { get; init; } = string.Empty;
    public string SupplierName { get; init; } = string.Empty;
}

/// <summary>
/// A container with everything the details page shows — the eight result sets of
/// logistics.usp_Container_Get read in one round trip: the header, the lines, the invoices, the
/// movements, the charges and their split over the lines, the attachments and the audit.
/// </summary>
public sealed record ContainerDto : ContainerStatusFlags
{
    public int Id { get; init; }
    public int DocumentTypeId { get; init; }
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

    /// <summary>The order the container was created from.</summary>
    public int? PurchaseOrderId { get; init; }

    public string? PurchaseOrderNumber { get; init; }
    public int? PurchaseOrderSupplierId { get; init; }
    public string? PurchaseOrderSupplierName { get; init; }
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

    /// <summary>
    /// The dispatch, port arrival, border crossing and customs release dates come from the movements
    /// (the container has travelled with one): the page shows them read-only.
    /// </summary>
    public bool DatesFromMovements { get; init; }

    /// <summary>A movement in progress or completed carries the container.</summary>
    public bool HasMovements { get; init; }

    public int InvoicedPostedBase { get; init; }
    public int InvoicedDraftBase { get; init; }

    /// <summary>Every line covered by POSTED invoices — what the offload needs.</summary>
    public bool IsFullyInvoiced { get; init; }

    public decimal ChargesPostedBase { get; init; }
    public decimal ChargesDraftBase { get; init; }

    /// <summary>Posted charges whose type enters the landed cost.</summary>
    public decimal ChargesLandedPostedBase { get; init; }

    public decimal? FobTotalBase { get; init; }
    public decimal? LandedTotalBase { get; init; }

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

    /// <summary>Charges are added until the container is offloaded, and after (a late charge = cost adjustment); not once closed.</summary>
    public bool CanAddCharge => Status is >= ContainerStatus.Draft and <= ContainerStatus.Offloaded;

    /// <summary>Still travelling and something loaded is not yet in an invoice (posted or draft).</summary>
    public bool CanInvoice
        => Status is >= ContainerStatus.Draft and <= ContainerStatus.Cleared
           && Lines.Any(l => l.AvailableToInvoiceBase > 0);

    /// <summary>The distinct suppliers of the loaded order lines, in line order.</summary>
    public IReadOnlyList<ContainerSupplierDto> Suppliers
        => Lines.DistinctBy(l => l.SupplierId)
            .Select(l => new ContainerSupplierDto { SupplierId = l.SupplierId, SupplierCode = l.SupplierCode, SupplierName = l.SupplierName })
            .ToList();

    public IReadOnlyList<ContainerLineDto> Lines { get; init; } = [];
    public IReadOnlyList<ContainerInvoiceDto> Invoices { get; init; } = [];

    /// <summary>The route, oldest first; cancelled movements last.</summary>
    public IReadOnlyList<ContainerMovementDto> Movements { get; init; } = [];

    public IReadOnlyList<ContainerChargeRowDto> Charges { get; init; } = [];
    public IReadOnlyList<ContainerChargeAllocationDto> Allocations { get; init; } = [];

    /// <summary>Newest first.</summary>
    public IReadOnlyList<ContainerAttachmentDto> Attachments { get; init; } = [];

    /// <summary>Newest first.</summary>
    public IReadOnlyList<ContainerAuditDto> Audit { get; init; } = [];

    protected override bool FullyInvoiced => IsFullyInvoiced;
}

/// <summary>
/// An approved order line that can still be loaded (logistics.usp_Container_AvailablePoLines).
/// Loadable = ordered − invoiced without a container − loaded in other containers.
/// </summary>
public sealed class AvailablePoLineDto
{
    public int PurchaseOrderId { get; init; }
    public string? PurchaseOrderNumber { get; init; }
    public DateTime OrderDate { get; init; }
    public byte OrderStatus { get; init; }
    public int SupplierId { get; init; }
    public string SupplierCode { get; init; } = string.Empty;
    public string SupplierName { get; init; } = string.Empty;
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public int PoLineId { get; init; }
    public int PoLineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string? Model { get; init; }
    public string? BrandName { get; init; }
    public int ItemUnitId { get; init; }
    public string UnitTypeName { get; init; } = string.Empty;
    public int PackingFormula { get; init; }
    public int OrderedQuantity { get; init; }
    public int OrderedBase { get; init; }

    /// <summary>In invoices made straight from the order (local receipts), draft or posted.</summary>
    public int InvoicedDirectBase { get; init; }

    public int LoadedElsewhereBase { get; init; }

    /// <summary>What the container being edited already holds (0 for a new one).</summary>
    public int LoadedHereBase { get; init; }

    /// <summary>The ceiling for this container: ordered − invoiced directly − loaded elsewhere.</summary>
    public int MaxHereBase { get; init; }

    /// <summary>MaxHereBase − LoadedHereBase: what is still free to add.</summary>
    public int AvailableBase { get; init; }

    public decimal UnitPrice { get; init; }
    public decimal DiscountPercent { get; init; }
    public decimal? UnitValueBase { get; init; }

    /// <summary>The item's oil per unit — the default when the line is loaded with oil.</summary>
    public decimal? ItemOilQtyPerUnit { get; init; }

    /// <summary>Pieces per container from the item's container unit (script 25); null when it has none.</summary>
    public int? PcPerContainer { get; init; }

    public decimal? WeightKg { get; init; }
    public decimal? VolumeCbm { get; init; }
}

/// <summary>
/// A container line that can still be invoiced (logistics.usp_Container_InvoiceCandidates):
/// containers not offloaded, closed or cancelled.
/// </summary>
public sealed class InvoiceCandidateDto
{
    public int ContainerLineId { get; init; }
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public byte ContainerStatus { get; init; }
    public int LineNumber { get; init; }
    public int PurchaseOrderId { get; init; }
    public string? PurchaseOrderNumber { get; init; }
    public byte OrderStatus { get; init; }
    public int SupplierId { get; init; }
    public string SupplierName { get; init; } = string.Empty;
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public int PoLineId { get; init; }
    public int PoLineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public int PoItemUnitId { get; init; }
    public string PoUnitTypeName { get; init; } = string.Empty;
    public int PoPackingFormula { get; init; }
    public decimal UnitPrice { get; init; }
    public decimal DiscountPercent { get; init; }
    public int LoadedBase { get; init; }
    public int InvoicedPostedBase { get; init; }
    public int InvoicedDraftBase { get; init; }
    public int AvailableBase { get; init; }

    /// <summary>What the order line still allows (posted invoices and drafts deducted).</summary>
    public int OrderLineRemainingBase { get; init; }
}

/* ── requests ──────────────────────────────────────────────────────────────────────────────── */

/// <summary>One line of logistics.tvp_ContainerLoadLine: an order line and the pieces loaded.</summary>
public sealed class SaveContainerLineRequest
{
    public int LineNumber { get; init; }

    /// <summary>Identifies the line: unique in the container.</summary>
    [Range(1, int.MaxValue)]
    public int PoLineId { get; init; }

    /// <summary>In BASE units (pieces).</summary>
    [Range(1, int.MaxValue)]
    public int QuantityBase { get; init; }

    public bool OilIncluded { get; init; }

    /// <summary>Null = the item's value (when oil is included).</summary>
    [Range(0, 9999999.99)]
    public decimal? OilQtyPerUnit { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }
}

public sealed class SaveContainerRequest
{
    /// <summary>Required when creating: a container is created from an approved purchase order. Ignored on an update.</summary>
    public int? PurchaseOrderId { get; init; }

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

    /* The four milestone dates are replaced by the movements once the container travels with one. */
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

    /// <summary>The whole loading plan: lines left out are removed (refused when invoiced).</summary>
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

/// <summary>Cancelling a container, or reversing its offload: both need a reason.</summary>
public sealed class CancelRequest
{
    [Required]
    [StringLength(300, MinimumLength = 1)]
    public string Reason { get; init; } = string.Empty;

    public string? RowVersion { get; init; }
}

/// <summary>Confirm, Close and Reopen carry nothing but the version the caller saw.</summary>
public sealed class ContainerActionRequest
{
    public string? RowVersion { get; init; }
}

public sealed class ContainerQuery
{
    /// <summary>Ref, container no., B/L, vessel, PO / PI no., commercial invoice no., exporter ref. or supplier (contains).</summary>
    public string? Search { get; init; }

    public string? ContainerRef { get; init; }
    public string? ContainerNo { get; init; }
    public int? SupplierId { get; init; }

    /// <summary>A purchase order OR a purchase invoice linked to the container.</summary>
    public int? PurchaseDocumentId { get; init; }

    /// <summary>Containers carrying lines of this order.</summary>
    public int? PurchaseOrderId { get; init; }

    /// <summary>Containers of this movement.</summary>
    public int? MovementId { get; init; }

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

public sealed class AvailablePoLineQuery
{
    /// <summary>Lines of this order only; null = any approved, open order.</summary>
    public int? PurchaseOrderId { get; init; }

    public int? SupplierId { get; init; }

    /// <summary>Order number, item code or name, supplier name (contains).</summary>
    public string? Search { get; init; }

    /// <summary>The container being edited: what it already holds counts apart (LoadedHereBase).</summary>
    public int? ContainerId { get; init; }

    [Range(1, 500)]
    public int Top { get; init; } = 200;
}

public sealed class InvoiceCandidateQuery
{
    public int? PurchaseOrderId { get; init; }
    public int? ContainerId { get; init; }

    /// <summary>Also the lines already fully invoiced.</summary>
    public bool IncludeAll { get; init; }
}
