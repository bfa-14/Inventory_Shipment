using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Logistics;

/* Shipment movements (script 27): one leg of the route — loading, sea freight, transshipment, port,
   inland transport, border, customs, delivery — carrying one or more containers. The STAGE of the
   movement type is what moves the container status; the movement itself only has four states. */

/// <summary>What a movement type represents for the containers it carries.</summary>
public static class MovementStages
{
    /// <summary>Loading at the supplier: no status change.</summary>
    public const string Origin = "Origin";

    /// <summary>Started = in transit (dispatch date), completed = at port (port arrival).</summary>
    public const string Sea = "Sea";

    /// <summary>Started = in transit (transshipment, inland transport).</summary>
    public const string Transit = "Transit";

    /// <summary>Started = at port (port arrival).</summary>
    public const string Port = "Port";

    /// <summary>Started = in transit, border crossing date.</summary>
    public const string Border = "Border";

    /// <summary>Completed = cleared (customs release date).</summary>
    public const string Customs = "Customs";

    /// <summary>Started = cleared (on its way to the warehouse).</summary>
    public const string Delivery = "Delivery";

    public static readonly string[] All = [Origin, Sea, Transit, Port, Border, Customs, Delivery];

    public static string? Normalize(string? stage)
        => All.FirstOrDefault(s => string.Equals(s, stage, StringComparison.OrdinalIgnoreCase));
}

/// <summary>Planned → In progress (Start) → Completed (Complete); Cancelled.</summary>
public static class MovementStatus
{
    public const byte Planned = 1;
    public const byte InProgress = 2;
    public const byte Completed = 3;
    public const byte Cancelled = 4;

    private static readonly string[] Names = ["Planned", "In Progress", "Completed", "Cancelled"];

    public static string Name(byte status)
        => status is >= Planned and <= Cancelled ? Names[status - 1] : "Unknown";

    /// <summary>The code 1–4, or a name with or without the space; null when neither.</summary>
    public static byte? ToCode(string? status)
    {
        if (string.IsNullOrWhiteSpace(status))
        {
            return null;
        }

        if (byte.TryParse(status, out var code) && code is >= Planned and <= Cancelled)
        {
            return code;
        }

        var compact = status.Replace(" ", string.Empty, StringComparison.Ordinal);
        var index = Array.FindIndex(Names, n =>
            string.Equals(n.Replace(" ", string.Empty, StringComparison.Ordinal), compact, StringComparison.OrdinalIgnoreCase));
        return index >= 0 ? (byte)(index + 1) : null;
    }
}

/* ── movement types (master data) ──────────────────────────────────────────────────────────── */

public class MovementTypeDto
{
    public int Id { get; init; }
    public string TypeCode { get; init; } = string.Empty;
    public string TypeName { get; init; } = string.Empty;

    /// <summary>Origin, Sea, Transit, Port, Border, Customs or Delivery (see <see cref="MovementStages"/>).</summary>
    public string Stage { get; init; } = MovementStages.Transit;

    public int SortOrder { get; init; }
    public bool IsActive { get; init; }

    /// <summary>Movements using the type. Only the list computes it; a single read leaves it 0.</summary>
    public int UsedCount { get; init; }

    public DateTime CreatedAtUtc { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

public sealed class MovementTypeLookupDto
{
    public int Id { get; init; }
    public string TypeCode { get; init; } = string.Empty;
    public string TypeName { get; init; } = string.Empty;
    public string Stage { get; init; } = MovementStages.Transit;
    public int SortOrder { get; init; }
    public bool IsActive { get; init; }
}

public sealed class MovementTypeQuery
{
    public string? Search { get; init; }
    public string? Stage { get; init; }
    public bool? IsActive { get; init; }

    /// <summary>SortOrder, TypeCode, TypeName, Stage or IsActive.</summary>
    public string SortBy { get; init; } = "SortOrder";

    public string SortDir { get; init; } = "asc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}

public sealed class SaveMovementTypeRequest : IValidatableObject
{
    [Required]
    [StringLength(10, MinimumLength = 1)]
    public string TypeCode { get; init; } = string.Empty;

    [Required]
    [StringLength(100, MinimumLength = 1)]
    public string TypeName { get; init; } = string.Empty;

    /// <summary>Cannot change once movements use the type (409 IN_USE).</summary>
    [Required]
    [StringLength(10)]
    public string Stage { get; init; } = MovementStages.Transit;

    public int SortOrder { get; init; }
    public bool IsActive { get; init; } = true;
    public string? RowVersion { get; init; }

    public IEnumerable<ValidationResult> Validate(ValidationContext validationContext)
    {
        if (MovementStages.Normalize(Stage) is null)
        {
            yield return new ValidationResult(
                "Stage must be Origin, Sea, Transit, Port, Border, Customs or Delivery.", [nameof(Stage)]);
        }
    }
}

/* ── movements ─────────────────────────────────────────────────────────────────────────────── */

/// <summary>What a movement's STATUS allows; the permission is checked separately.</summary>
public abstract record MovementStatusFlags
{
    public byte Status { get; init; }
    public string StatusName => MovementStatus.Name(Status);

    /// <summary>Planned: everything; in progress: the header, the start date and the containers.</summary>
    public bool CanEdit => Status is MovementStatus.Planned or MovementStatus.InProgress;

    public bool CanStart => Status == MovementStatus.Planned;
    public bool CanComplete => Status == MovementStatus.InProgress;
    public bool CanCancel => Status is >= MovementStatus.Planned and <= MovementStatus.Completed;
    public bool CanDelete => Status == MovementStatus.Planned;
}

/// <summary>One row of the movement list (logistics.usp_Movement_Search).</summary>
public record MovementListDto : MovementStatusFlags
{
    public int Id { get; init; }
    public string MovementNo { get; init; } = string.Empty;
    public int MovementTypeId { get; init; }
    public string TypeCode { get; init; } = string.Empty;
    public string TypeName { get; init; } = string.Empty;
    public string Stage { get; init; } = string.Empty;
    public int FromPlaceId { get; init; }
    public string FromCode { get; init; } = string.Empty;
    public string FromName { get; init; } = string.Empty;
    public string FromKind { get; init; } = string.Empty;
    public int ToPlaceId { get; init; }
    public string ToCode { get; init; } = string.Empty;
    public string ToName { get; init; } = string.Empty;
    public string ToKind { get; init; } = string.Empty;
    public DateTime? PlannedDate { get; init; }
    public DateTime? StartDate { get; init; }
    public DateTime? Eta { get; init; }
    public DateTime? EndDate { get; init; }
    public int? CarrierPartyId { get; init; }
    public string? CarrierName { get; init; }
    public string? VehicleOrVessel { get; init; }
    public string? VoyageNo { get; init; }
    public string? Reference { get; init; }
    public int ContainerCount { get; init; }

    /// <summary>"KTG-2026-0006 +1".</summary>
    public string? ContainerRefs { get; init; }

    public decimal? ChargesPostedBase { get; init; }
    public int AttachmentCount { get; init; }

    /// <summary>From the start to the end (or today).</summary>
    public int? DurationDays { get; init; }

    /// <summary>Planned or in progress, and the ETA is behind us.</summary>
    public bool IsLate { get; init; }

    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

/// <summary>A container the movement carries (set 2 of logistics.usp_Movement_Get).</summary>
public sealed class MovementContainerDto
{
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public string ContainerTypeCode { get; init; } = string.Empty;
    public byte ContainerStatus { get; init; }
    public string ContainerStatusName => Logistics.ContainerStatus.Name(ContainerStatus);
    public string? CurrentLocation { get; init; }
    public int TotalAllocatedBase { get; init; }
    public decimal TotalOilQty { get; init; }
    public string? ItemSummary { get; init; }
    public string? SupplierName { get; init; }

    /// <summary>Posted / draft charges of this container linked to the movement.</summary>
    public decimal? ChargesBase { get; init; }

    public decimal? DraftChargesBase { get; init; }
    public int AttachmentCount { get; init; }
    public byte[] ContainerRowVersion { get; init; } = [];
}

/// <summary>A charge linked to the movement (set 3).</summary>
public sealed class MovementChargeDto
{
    public int Id { get; init; }
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public Guid? GroupId { get; init; }
    public int ChargeTypeId { get; init; }
    public string ChargeCode { get; init; } = string.Empty;
    public string ChargeName { get; init; } = string.Empty;
    public string? Description { get; init; }
    public string? ProviderName { get; init; }
    public string? Reference { get; init; }
    public DateTime ChargeDate { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public decimal Amount { get; init; }
    public decimal AmountBase { get; init; }
    public string AllocationMethod { get; init; } = string.Empty;
    public bool IncludeInLandedCost { get; init; }

    /// <summary>1 Draft, 2 Posted, 3 Cancelled.</summary>
    public byte Status { get; init; }

    public byte[] RowVersion { get; init; } = [];
}

/// <summary>A document linked to the movement (set 4) — one row per container holding it.</summary>
public sealed class MovementAttachmentDto
{
    public int Id { get; init; }
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public int? ChargeId { get; init; }
    public int? AttachmentTypeId { get; init; }
    public string? Category { get; init; }
    public string? SubType { get; init; }
    public int FileId { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public int SizeBytes { get; init; }
    public string? Note { get; init; }
    public DateTime? DocumentDate { get; init; }
    public Guid? GroupId { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
}

/// <summary>A movement with its containers, charges and documents — the four sets of logistics.usp_Movement_Get.</summary>
public sealed record MovementDto : MovementStatusFlags
{
    public int Id { get; init; }
    public int DocumentTypeId { get; init; }
    public string MovementNo { get; init; } = string.Empty;
    public int MovementTypeId { get; init; }
    public string TypeCode { get; init; } = string.Empty;
    public string TypeName { get; init; } = string.Empty;
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
    public string? CancelReason { get; init; }
    public int? CarrierPartyId { get; init; }
    public string? CarrierName { get; init; }
    public string? VehicleOrVessel { get; init; }
    public string? VoyageNo { get; init; }
    public string? Reference { get; init; }
    public string? Notes { get; init; }
    public DateTime? StartedAtUtc { get; init; }
    public string? StartedByName { get; init; }
    public DateTime? CompletedAtUtc { get; init; }
    public string? CompletedByName { get; init; }
    public DateTime? CancelledAtUtc { get; init; }
    public string? CancelledByName { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public string? UpdatedByName { get; init; }
    public byte[] RowVersion { get; init; } = [];

    /// <summary>Planned or in progress, and the ETA is behind us.</summary>
    public bool IsLate
        => Status is MovementStatus.Planned or MovementStatus.InProgress
           && Eta is { } eta && eta.Date < DateTime.UtcNow.Date;

    public IReadOnlyList<MovementContainerDto> Containers { get; init; } = [];
    public IReadOnlyList<MovementChargeDto> Charges { get; init; } = [];
    public IReadOnlyList<MovementAttachmentDto> Attachments { get; init; } = [];
}

public sealed class SaveMovementRequest
{
    [Range(1, int.MaxValue)]
    public int MovementTypeId { get; init; }

    [Range(1, int.MaxValue)]
    public int FromPlaceId { get; init; }

    /// <summary>For Port / Customs / Border types the page defaults it to the departure place.</summary>
    [Range(1, int.MaxValue)]
    public int ToPlaceId { get; init; }

    public DateOnly? PlannedDate { get; init; }

    /// <summary>Only while in progress (Start sets it); ignored on a planned movement.</summary>
    public DateOnly? StartDate { get; init; }

    public DateOnly? Eta { get; init; }
    public int? CarrierPartyId { get; init; }

    [StringLength(100)]
    public string? VehicleOrVessel { get; init; }

    [StringLength(30)]
    public string? VoyageNo { get; init; }

    [StringLength(50)]
    public string? Reference { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    /// <summary>At least one. Confirmed containers only once the movement is in progress.</summary>
    public IReadOnlyList<int> ContainerIds { get; init; } = [];

    public string? RowVersion { get; init; }
}

/// <summary>Start, Complete (date = start / end date, default today) or Cancel (reason required).</summary>
public sealed class MovementStatusRequest
{
    public DateOnly? Date { get; init; }

    [StringLength(300)]
    public string? Reason { get; init; }

    public string? RowVersion { get; init; }
}

/// <summary>
/// One movement for the chosen containers (logistics.usp_Movement_ShipContainers): the drafts
/// confirmed, the movement created and started, the shipping details copied to the containers — in
/// one transaction.
/// </summary>
public sealed class ShipContainersRequest
{
    /// <summary>At least one.</summary>
    public IReadOnlyList<int> ContainerIds { get; init; } = [];

    /// <summary>Null = SEA.</summary>
    public int? MovementTypeId { get; init; }

    /// <summary>Null = the containers' common port of loading (Sea only).</summary>
    public int? FromPlaceId { get; init; }

    /// <summary>Null = the containers' common port of destination (Sea only).</summary>
    public int? ToPlaceId { get; init; }

    /// <summary>Null = today (the planned date when startNow is false).</summary>
    public DateOnly? StartDate { get; init; }

    public DateOnly? Eta { get; init; }
    public int? CarrierPartyId { get; init; }

    [StringLength(100)]
    public string? VehicleOrVessel { get; init; }

    [StringLength(30)]
    public string? VoyageNo { get; init; }

    /// <summary>Booking, waybill, declaration...</summary>
    [StringLength(50)]
    public string? Reference { get; init; }

    [StringLength(30)]
    public string? BlNo { get; init; }

    public DateOnly? BlDate { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    /// <summary>False = the movement stays planned.</summary>
    public bool StartNow { get; init; } = true;

    /// <summary>Confirm the drafts among the containers. Only honoured with containers.confirm.</summary>
    public bool ConfirmDrafts { get; init; } = true;

    /// <summary>Copy vessel, voyage, shipping line, B/L and ETA (and the ports when missing) to the containers.</summary>
    public bool UpdateContainers { get; init; } = true;
}

/// <summary>The movement created for the chosen containers.</summary>
public sealed class ShippedMovementDto
{
    public int Id { get; init; }
    public string MovementNo { get; init; } = string.Empty;
    public byte Status { get; init; }
    public DateTime? StartDate { get; init; }
    public DateTime? PlannedDate { get; init; }
    public DateTime? Eta { get; init; }
    public int ContainerCount { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

public sealed class MovementQuery
{
    /// <summary>Movement no., vessel / truck, voyage, reference, container ref / no. (contains).</summary>
    public string? Search { get; init; }

    /// <summary>The code 1–4 or the name (Planned, InProgress / "In Progress", Completed, Cancelled).</summary>
    public string? Status { get; init; }

    public int? MovementTypeId { get; init; }

    /// <summary>From or to.</summary>
    public int? PlaceId { get; init; }

    public int? ContainerId { get; init; }
    public int? CarrierPartyId { get; init; }

    /// <summary>Start date, else planned date.</summary>
    public DateOnly? DateFrom { get; init; }

    public DateOnly? DateTo { get; init; }

    /// <summary>MovementNo, StartDate, Eta, EndDate, Status or CreatedAtUtc.</summary>
    public string SortBy { get; init; } = "StartDate";

    public string SortDir { get; init; } = "desc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}

/* ── tracking board ────────────────────────────────────────────────────────────────────────── */

/// <summary>A container on the tracking board (set 1 of logistics.usp_Container_Tracking).</summary>
public sealed class TrackingContainerDto
{
    public int Id { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public string ContainerTypeCode { get; init; } = string.Empty;
    public byte Status { get; init; }
    public string StatusName => ContainerStatus.Name(Status);
    public string? CurrentLocation { get; init; }
    public DateTime? DispatchDate { get; init; }
    public DateTime? Eta { get; init; }
    public DateTime? ActualPortArrival { get; init; }
    public DateTime? CustomsReleaseDate { get; init; }
    public DateTime? OffloadedDate { get; init; }
    public DateTime? LastFreeDay { get; init; }
    public int? DaysAtPort { get; init; }
    public int TotalAllocatedBase { get; init; }
    public decimal TotalOilQty { get; init; }
    public string? ItemSummary { get; init; }
    public string? SupplierName { get; init; }
    public string? PortOfLoadingName { get; init; }
    public string? PortOfDestinationName { get; init; }
    public string? FinalDestinationName { get; init; }
    public string? WarehouseName { get; init; }
}

/// <summary>One leg of a container's route (set 2): cancelled movements are left out.</summary>
public sealed class TrackingLegDto
{
    public int ContainerId { get; init; }
    public int MovementId { get; init; }
    public string MovementNo { get; init; } = string.Empty;

    /// <summary>1-based, in route order per container.</summary>
    public long Seq { get; init; }

    public string TypeCode { get; init; } = string.Empty;
    public string TypeName { get; init; } = string.Empty;
    public string Stage { get; init; } = string.Empty;
    public int FromPlaceId { get; init; }
    public string FromCode { get; init; } = string.Empty;
    public string FromName { get; init; } = string.Empty;
    public string FromKind { get; init; } = string.Empty;
    public string? FromCountry { get; init; }
    public int ToPlaceId { get; init; }
    public string ToCode { get; init; } = string.Empty;
    public string ToName { get; init; } = string.Empty;
    public string ToKind { get; init; } = string.Empty;
    public string? ToCountry { get; init; }
    public DateTime? PlannedDate { get; init; }
    public DateTime? StartDate { get; init; }
    public DateTime? Eta { get; init; }
    public DateTime? EndDate { get; init; }

    /// <summary>1 planned, 2 in progress, 3 completed.</summary>
    public byte Status { get; init; }

    public string? CarrierName { get; init; }
    public string? VehicleOrVessel { get; init; }
    public string? VoyageNo { get; init; }

    /// <summary>Where the container stands on the leg, 0–100 (in progress: elapsed / planned duration, capped at 95).</summary>
    public int ProgressPct { get; init; }

    public bool IsLate { get; init; }
}

public sealed class TrackingDto
{
    public IReadOnlyList<TrackingContainerDto> Containers { get; init; } = [];
    public IReadOnlyList<TrackingLegDto> Legs { get; init; } = [];
}

public sealed class TrackingQuery
{
    /// <summary>One container (whatever its status); null = the open ones and those offloaded recently.</summary>
    public int? ContainerId { get; init; }

    /// <summary>Ref, container no., B/L or vessel (contains).</summary>
    public string? Search { get; init; }

    /// <summary>How long offloaded containers stay on the board.</summary>
    [Range(0, 3650)]
    public int OffloadedDays { get; init; } = 30;
}

/* ── attachments ───────────────────────────────────────────────────────────────────────────── */

/// <summary>A record created by an upload: one per container, the same file id on all of them.</summary>
public sealed class ContainerAttachmentCreatedDto
{
    public int Id { get; init; }
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public int FileId { get; init; }
    public int? MovementId { get; init; }
    public int? ChargeId { get; init; }
}

/// <summary>A file on its way into logistics.Files, with the containers and links the page chose.</summary>
public sealed class ContainerAttachmentUpload
{
    public IReadOnlyList<int> ContainerIds { get; init; } = [];
    public int? MovementId { get; init; }
    public int? ChargeId { get; init; }
    public int? AttachmentTypeId { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public byte[] Content { get; init; } = [];
    public string? Note { get; init; }
    public DateOnly? DocumentDate { get; init; }
}

/// <summary>The edited details of a container attachment; Content null keeps the stored file.</summary>
public sealed class ContainerAttachmentEdit
{
    public int? AttachmentTypeId { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string? ContentType { get; init; }
    public byte[]? Content { get; init; }
    public string? Note { get; init; }
    public DateOnly? DocumentDate { get; init; }
}

public sealed class ContainerAttachmentFile
{
    public int Id { get; init; }
    public int ContainerId { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public int SizeBytes { get; init; }
    public byte[] Content { get; init; } = [];
}
