using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Logistics;

/* THE NEXT STEP OF A CONTAINER (script 81, shipment phase 2): one "Next step..." for one container or 300, already
   filled in. The database says what each container's next step is (logistics.fn_Container_NextStep), proposes its next
   leg (the usual one from where it is, else its own ports, else the stage order), and groups many containers by step
   (logistics.usp_Container_NextStepPreview). Applying a step never bypasses a movement: a Complete or a Start goes
   through the movement's own Complete / Start (so a completed Delivery still drafts its goods receipts after the commit),
   and a new leg through logistics.usp_Movement_AddLeg, which saves and starts it with the movement procedures. */

/// <summary>The step of a container (logistics.fn_Container_NextStepKind), the first that applies.</summary>
public static class ContainerNextStepKinds
{
    /// <summary>Received, closed or cancelled: the journey is over (the reason says which).</summary>
    public const string Done = "Done";

    /// <summary>A movement in progress carries it: "Arrived at Dar es Salaam...", "Cleared customs at Kasumbalesa...".</summary>
    public const string Complete = "Complete";

    /// <summary>A draft goods receipt waits for it: "Open goods receipt (draft)".</summary>
    public const string OpenReceipt = "OpenReceipt";

    /// <summary>Its next planned movement waits: "Start Inland transport...".</summary>
    public const string StartPlanned = "StartPlanned";

    /// <summary>It never moved: "Start shipment...".</summary>
    public const string Ship = "Ship";

    /// <summary>Its last leg is a completed Delivery and nothing received it yet: "Receive goods...".</summary>
    public const string Receive = "Receive";

    /// <summary>Its last leg is completed: "Inland transport to Kasumbalesa...", "Next leg from Dar es Salaam...".</summary>
    public const string NextLeg = "NextLeg";

    /// <summary>The steps a group can apply (Receive goods... has its own dialogs).</summary>
    public static readonly string[] Applicable = [Complete, StartPlanned, Ship, NextLeg];

    /// <summary>The values of the Containers list's "Next step" filter; Receive also lists the open drafts.</summary>
    public static readonly string[] ListFilters = [Ship, StartPlanned, Complete, NextLeg, Receive];

    public static string? Normalize(string? kind, IEnumerable<string> among)
        => among.FirstOrDefault(k => string.Equals(k, kind?.Trim(), StringComparison.OrdinalIgnoreCase));

    /// <summary>A new leg (Ship or NextLeg): both go through the same procedure.</summary>
    public static bool IsNewLeg(string? kind) => kind is Ship or NextLeg;
}

/// <summary>Where the proposed leg came from (the hint under the type in the dialog).</summary>
public static class NextLegProposalSources
{
    /// <summary>"Suggested: the usual next leg from Dar es Salaam ({n} earlier legs)".</summary>
    public const string History = "History";

    /// <summary>"Suggested from the container's ports".</summary>
    public const string Ports = "Ports";

    /// <summary>"Suggested from the stages".</summary>
    public const string Stages = "Stages";

    /// <summary>No active movement type left to propose: "Choose the To".</summary>
    public const string None = "None";
}

/// <summary>
/// The next step of one container (result set 1 of logistics.usp_Container_NextStepPreview; GET next-step): what it is,
/// where the container is, the movement the step concerns (Complete, StartPlanned) with its RowVersion, the proposed
/// new leg (Ship, NextLeg) and, for a movement to complete, the leg proposed after it ("Then").
/// </summary>
public sealed record ContainerNextStepDto
{
    public int ContainerId { get; init; }

    /// <summary>False for an id that names no container ("Not found").</summary>
    public bool Found { get; init; }

    public string? ContainerRef { get; init; }
    public string? ContainerNo { get; init; }
    public byte? Status { get; init; }
    public string? StatusName => Status is { } status ? ContainerStatus.Name(status) : null;

    /// <summary>See <see cref="ContainerNextStepKinds"/>; null for an unknown id (<see cref="Found"/> false).</summary>
    public string? Kind { get; init; }

    /// <summary>Why the step cannot be taken at all ("Received into Lubumbashi Warehouse: the journey is over.").</summary>
    public string? BlockedReason { get; init; }

    /// <summary>A draft: it is confirmed first (with containers.confirm), the blue alert.</summary>
    public bool IsDraft { get; init; }

    /// <summary>False: the yellow "no container number" alert.</summary>
    public bool HasContainerNo { get; init; }

    /// <summary>Never moved, with dispatch / arrival dates typed by hand: the movements' dates will replace them.</summary>
    public bool HasTypedDates { get; init; }

    /* where it is */

    public int? MovementCount { get; init; }
    public int? PlaceId { get; init; }
    public string? PlaceName { get; init; }

    /// <summary>Sea, Border or Inland (masterdata.Ports.Kind).</summary>
    public string? PlaceKind { get; init; }

    /// <summary>"Now at Dar es Salaam since 12/10/2026 (end of MOV-2026-000046)."</summary>
    public DateTime? PlaceSince { get; init; }

    /// <summary>The stage of its last leg; null when it never moved.</summary>
    public string? LastStage { get; init; }

    public int? LastMovementId { get; init; }
    public string? LastMovementNo { get; init; }
    public DateTime? LastMovementEndDate { get; init; }

    /* the movement of the step (Complete: the one in progress; StartPlanned: the planned one) */

    public int? MovementId { get; init; }
    public string? MovementNo { get; init; }

    /// <summary>Sent back with the step: a movement changed since is refused (70004, 409).</summary>
    public byte[]? MovementRowVersion { get; init; }

    public byte? MovementStatus { get; init; }
    public int? MovementTypeId { get; init; }
    public string? MovementTypeCode { get; init; }
    public string? MovementTypeName { get; init; }
    public string? MovementStage { get; init; }
    public int? MovementFromPlaceId { get; init; }
    public string? MovementFromName { get; init; }
    public int? MovementToPlaceId { get; init; }
    public string? MovementToName { get; init; }
    public DateTime? MovementPlannedDate { get; init; }
    public DateTime? MovementStartDate { get; init; }
    public DateTime? MovementEta { get; init; }

    /// <summary>How many containers the movement carries: "All 12 containers of MOV-... arrive too".</summary>
    public int? MovementContainerCount { get; init; }

    /// <summary>The earliest date of the step: Complete its start, StartPlanned the end of the previous leg.</summary>
    public DateTime? MovementNotBefore { get; init; }

    /* its goods receipt (Receive, OpenReceipt) */

    public int? GoodsReceiptId { get; init; }
    public string? GoodsReceiptNumber { get; init; }
    public byte? GoodsReceiptStatus { get; init; }

    /* the proposed new leg (Ship, NextLeg) */

    public int? ProposedTypeId { get; init; }
    public string? ProposedTypeCode { get; init; }
    public string? ProposedTypeName { get; init; }
    public string? ProposedStage { get; init; }
    public int? ProposedFromPlaceId { get; init; }
    public string? ProposedFromName { get; init; }

    /// <summary>Null on a leg that moves: "Choose the To".</summary>
    public int? ProposedToPlaceId { get; init; }

    public string? ProposedToName { get; init; }

    /// <summary>See <see cref="NextLegProposalSources"/>.</summary>
    public string? ProposalSource { get; init; }

    /// <summary>With History: how many earlier legs it is based on.</summary>
    public int? ProposalLegs { get; init; }

    /// <summary>A stay (Port, Customs, Border): To = the place, "at Kasumbalesa".</summary>
    public bool? ProposedIsStay { get; init; }

    /// <summary>The bulk dialog's default: one movement per container for a truck leg.</summary>
    public bool? ProposedOnePerContainer { get; init; }

    /* the leg proposed after the movement it completes (the "Then" box; never after a Delivery) */

    public int? ThenTypeId { get; init; }
    public string? ThenTypeCode { get; init; }
    public string? ThenTypeName { get; init; }
    public string? ThenStage { get; init; }
    public int? ThenFromPlaceId { get; init; }
    public string? ThenFromName { get; init; }
    public int? ThenToPlaceId { get; init; }
    public string? ThenToName { get; init; }
    public string? ThenSource { get; init; }
    public int? ThenLegs { get; init; }
    public bool? ThenIsStay { get; init; }

    /// <summary>Ticked by default: a stay at the arrival place, or the leg after Customs / Border.</summary>
    public bool ThenDefault { get; init; }

    /* the shipping details a new leg starts from */

    public string? VesselName { get; init; }
    public string? VoyageNo { get; init; }
    public string? ShippingLine { get; init; }
    public string? BlNo { get; init; }
    public DateTime? BlDate { get; init; }
    public string? TruckNo { get; init; }
    public DateTime? ContainerEta { get; init; }

    /// <summary>"PO-BR-002-000042 +1", for information.</summary>
    public string? OrderNumbers { get; init; }

    public string? SupplierNames { get; init; }

    /* the preview */

    /// <summary>The "Cannot move on" heading it falls under; null when it can move on.</summary>
    public string? BlockGroup { get; init; }

    public bool CanMove { get; init; }

    /// <summary>Its group in <see cref="NextStepPreviewDto.Groups"/>: an opaque key, (step, movement, type, From, To).</summary>
    public string? GroupKey { get; init; }
}

/// <summary>
/// One group of ticked containers that can move on together (result set 2 of usp_Container_NextStepPreview): the same
/// step, movement, type, From and To. Containers at different places or bound elsewhere fall into groups of their own.
/// </summary>
public sealed class NextStepGroupDto
{
    public string GroupKey { get; init; } = string.Empty;

    /// <summary>Complete, StartPlanned, Ship or NextLeg.</summary>
    public string Kind { get; init; } = string.Empty;

    /// <summary>Complete / StartPlanned: the movement ("MOV-2026-000046"); null for a new leg ("new").</summary>
    public int? MovementId { get; init; }

    public string? MovementNo { get; init; }
    public byte[]? MovementRowVersion { get; init; }

    /// <summary>The movement's type, or the proposed one for a new leg.</summary>
    public int? MovementTypeId { get; init; }

    public string? MovementTypeCode { get; init; }
    public string? MovementTypeName { get; init; }
    public string? MovementStage { get; init; }
    public int? FromPlaceId { get; init; }
    public string? FromName { get; init; }
    public int? ToPlaceId { get; init; }
    public string? ToName { get; init; }
    public bool IsNewLeg { get; init; }
    public bool IsStay { get; init; }
    public DateTime? MovementStartDate { get; init; }
    public DateTime? MovementPlannedDate { get; init; }
    public DateTime? MovementEta { get; init; }

    /// <summary>The ticked containers of the group.</summary>
    public int Containers { get; init; }

    /// <summary>
    /// How many the movement carries: more than <see cref="Containers"/> on a Complete, "MOV-... is completed for all its
    /// 30 containers: the 10 not ticked arrive too."
    /// </summary>
    public int? MovementContainerCount { get; init; }

    /// <summary>The earliest date for every container of the group (a new leg leaves once the last one arrived).</summary>
    public DateTime? NotBefore { get; init; }

    public string? PlaceName { get; init; }
    public string? ProposalSource { get; init; }
    public int? ProposalLegs { get; init; }

    /// <summary>The default of "One movement for the group" / "One per container".</summary>
    public bool OnePerContainer { get; init; }

    public int Drafts { get; init; }
    public int WithoutContainerNo { get; init; }
    public int WithTypedDates { get; init; }
    public int? OrderCount { get; init; }
    public int? SupplierCount { get; init; }
    public string? OrderNumbers { get; init; }
    public string? SupplierNames { get; init; }

    /* "Then start the suggested next leg on the same day" (Complete groups) */

    /// <summary>How many containers of the group get a next leg after it.</summary>
    public int ThenContainers { get; init; }

    /// <summary>Every container of the group gets the same next leg: the fields below describe it.</summary>
    public bool ThenSame { get; init; }

    public int? ThenTypeId { get; init; }
    public string? ThenTypeName { get; init; }
    public string? ThenStage { get; init; }
    public int? ThenFromPlaceId { get; init; }
    public string? ThenFromName { get; init; }
    public int? ThenToPlaceId { get; init; }
    public string? ThenToName { get; init; }
    public bool? ThenIsStay { get; init; }
    public string? ThenSource { get; init; }
    public int? ThenLegs { get; init; }
    public bool ThenDefault { get; init; }
}

/// <summary>The ticked containers that cannot move on, by reason ("Received, closed or cancelled (12)").</summary>
public sealed class NextStepBlockedDto
{
    public string BlockGroup { get; init; } = string.Empty;
    public int Containers { get; init; }

    /// <summary>The first five refs.</summary>
    public string? ContainerRefs { get; init; }
}

/// <summary>The "Next step..." dialog for ticked containers: one row each, the groups, the ones that cannot move on.</summary>
public sealed class NextStepPreviewDto
{
    public IReadOnlyList<ContainerNextStepDto> Containers { get; init; } = [];
    public IReadOnlyList<NextStepGroupDto> Groups { get; init; } = [];
    public IReadOnlyList<NextStepBlockedDto> Blocked { get; init; } = [];
}

public sealed class NextStepPreviewRequest
{
    /// <summary>1 to 5,000.</summary>
    public IReadOnlyList<int> ContainerIds { get; init; } = [];
}

/* ── applying ─────────────────────────────────────────────────────────────────────────────── */

/// <summary>The groups to apply, each on its own: one refusal never stops the others.</summary>
public sealed class ApplyNextStepRequest
{
    public IReadOnlyList<NextStepGroupRequest> Groups { get; init; } = [];
}

/// <summary>
/// One step for a group of containers. Complete / StartPlanned: movementId and rowVersion of the preview (the date is the
/// end / start date). Ship / NextLeg: a new leg from where the containers are (fromPlaceId empty = their place), the
/// type and To of the preview unless changed; startNow false plans it for the date.
/// </summary>
public sealed class NextStepGroupRequest
{
    /// <summary>Echoed on the result (the preview's groupKey, or any key of the caller's).</summary>
    [StringLength(200)]
    public string? Key { get; init; }

    /// <summary>Complete, StartPlanned, Ship or NextLeg.</summary>
    public string Kind { get; init; } = string.Empty;

    public int? MovementId { get; init; }
    public string? RowVersion { get; init; }

    /// <summary>The ticked containers of the group, each in one group only.</summary>
    public IReadOnlyList<int> ContainerIds { get; init; } = [];

    /// <summary>A new leg: null = the proposed type.</summary>
    public int? MovementTypeId { get; init; }

    /// <summary>
    /// A new leg: null = where the containers are. Given for a container that never moved and has no port of loading
    /// (any From fits it), and for a Loading at the supplier.
    /// </summary>
    public int? FromPlaceId { get; init; }

    /// <summary>
    /// A new leg: the place the preview saw the containers at (its placeId / the group's fromPlaceId). When they are
    /// somewhere else now - someone moved them while the dialog stood open - the step is refused as changed instead of
    /// making a leg from their new place with the To chosen for the old one. Null = not checked.
    /// </summary>
    public int? ExpectedPlaceId { get; init; }

    /// <summary>A new leg: null = the proposed To (a stay: the From).</summary>
    public int? ToPlaceId { get; init; }

    /// <summary>A new leg: false = the movement stays planned for <see cref="Date"/>.</summary>
    public bool StartNow { get; init; } = true;

    /// <summary>Complete: the end date; StartPlanned and a new leg: the start (or planned) date. Null = today.</summary>
    public DateOnly? Date { get; init; }

    public DateOnly? Eta { get; init; }
    public int? CarrierPartyId { get; init; }

    [StringLength(100)]
    public string? VehicleOrVessel { get; init; }

    [StringLength(30)]
    public string? VoyageNo { get; init; }

    [StringLength(50)]
    public string? Reference { get; init; }

    [StringLength(30)]
    public string? BlNo { get; init; }

    public DateOnly? BlDate { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    /// <summary>A new leg: one movement per container (one truck each, each arriving on its own day).</summary>
    public bool OnePerContainer { get; init; }

    /// <summary>One per container: each container's truck no. (or vessel) and ETA, else the group's.</summary>
    public IReadOnlyList<NextStepLegContainerRequest>? PerContainer { get; init; }

    /// <summary>Copy vessel, voyage, B/L and ETA (a truck leg: the truck no.) to the containers.</summary>
    public bool CopyToContainers { get; init; } = true;

    /// <summary>Complete only: then start the suggested next leg, a second step after the completion is committed.</summary>
    public NextStepThenRequest? Then { get; init; }
}

public sealed class NextStepLegContainerRequest
{
    public int ContainerId { get; init; }

    [StringLength(100)]
    public string? VehicleOrVessel { get; init; }

    public DateOnly? Eta { get; init; }
}

/// <summary>"Then start Customs clearance at Kasumbalesa on the same day": the leg proposed once the containers arrived.</summary>
public sealed class NextStepThenRequest
{
    /// <summary>False = plan it only.</summary>
    public bool StartNow { get; init; } = true;

    /// <summary>Null = the completion's date ("on the same day").</summary>
    public DateOnly? Date { get; init; }

    /// <summary>Null = the proposed type.</summary>
    public int? MovementTypeId { get; init; }

    /// <summary>Null = the proposed To (a stay: the place).</summary>
    public int? ToPlaceId { get; init; }

    /// <summary>Null = the proposal's default (one per container for a truck leg).</summary>
    public bool? OnePerContainer { get; init; }
}

/// <summary>The result of one group, in the order of the request.</summary>
public sealed class NextStepGroupResultDto
{
    public string? Key { get; init; }
    public string Kind { get; init; } = string.Empty;
    public bool Ok { get; init; }

    /// <summary>The refusal's code (CONTAINER_BUSY, START_BEFORE_PREVIOUS_LEG, CONCURRENCY...); null when applied.</summary>
    public string? Code { get; init; }

    /// <summary>
    /// What happened ("KTG-2026-0031: arrived at Dar es Salaam on 17/10/2026 (MOV-2026-000046). Now At Port."), or the
    /// refusal as the database gave it.
    /// </summary>
    public string Message { get; init; } = string.Empty;

    public IReadOnlyList<int> ContainerIds { get; init; } = [];

    /// <summary>The movement completed or started, or the new legs created.</summary>
    public IReadOnlyList<NextStepMovementDto> Movements { get; init; } = [];

    /// <summary>The legs the "Then" box started (or planned).</summary>
    public IReadOnlyList<NextStepMovementDto> ThenMovements { get; init; } = [];

    /// <summary>A completed Delivery: the draft goods receipts made after the commit (as the movement's Complete).</summary>
    public IReadOnlyList<MovementReceiptResultDto>? GoodsReceipts { get; init; }

    public string? GoodsReceiptsMessage { get; init; }

    /// <summary>
    /// Said beside a step that was applied: a draft goods receipt not made, or "Arrival recorded; Customs clearance was not
    /// started: {reason}. Use Next step…".
    /// </summary>
    public IReadOnlyList<string> Warnings { get; init; } = [];
}

public sealed class NextStepMovementDto
{
    public int Id { get; init; }
    public string MovementNo { get; init; } = string.Empty;
    public byte Status { get; init; }
    public string StatusName => MovementStatus.Name(Status);

    /// <summary>One per container: its container.</summary>
    public int? ContainerId { get; init; }

    public string? ContainerRef { get; init; }
}

/// <summary>A new leg for a group of containers, as logistics.usp_Movement_AddLeg takes it.</summary>
public sealed record AddLegCommand
{
    public IReadOnlyList<int> ContainerIds { get; init; } = [];
    public int? MovementTypeId { get; init; }
    public int? FromPlaceId { get; init; }
    public int? ToPlaceId { get; init; }
    public DateOnly? StartDate { get; init; }
    public DateOnly? Eta { get; init; }
    public int? CarrierPartyId { get; init; }
    public string? VehicleOrVessel { get; init; }
    public string? VoyageNo { get; init; }
    public string? Reference { get; init; }
    public string? BlNo { get; init; }
    public DateOnly? BlDate { get; init; }
    public string? Notes { get; init; }
    public bool StartNow { get; init; } = true;
    public bool UpdateContainers { get; init; } = true;
    public bool OnePerContainer { get; init; }
    public IReadOnlyList<NextStepLegContainerRequest> PerContainer { get; init; } = [];
}

/// <summary>One movement made by usp_Movement_AddLeg (ContainerId: its container when one per container).</summary>
public sealed class AddedLegDto
{
    public int Id { get; init; }
    public string MovementNo { get; init; } = string.Empty;
    public byte Status { get; init; }
    public DateTime? StartDate { get; init; }
    public DateTime? PlannedDate { get; init; }
    public DateTime? Eta { get; init; }
    public int ContainerCount { get; init; }
    public int? ContainerId { get; init; }
    public string? ContainerRef { get; init; }
    public byte[] RowVersion { get; init; } = [];
}
