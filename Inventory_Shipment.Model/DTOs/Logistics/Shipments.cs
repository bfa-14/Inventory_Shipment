namespace Inventory_Shipment.Model.DTOs.Logistics;

/* THE SHIPMENTS BOARD (script 82, shipment phase 3): Logistics › Shipments shows every container on its way in one column
   by stage - At supplier, At sea, At port, On the road, At border / customs, Delivered, to receive (and with its switch
   the ones received in the last 30 days). Where a container stands is worked out in ONE place, the database
   (logistics.fn_Container_BoardPhase), from the same movements as its next step (phases 1 and 2), so the board, the
   container page and the Containers list never disagree. Every move still goes through the Next step dialogs: a move
   writes a movement with its dates, so the board has no drag-and-drop. */

/// <summary>The columns of the board, left to right (logistics.fn_Container_BoardPhase).</summary>
public static class ShipmentPhases
{
    /// <summary>Never started a leg, or a Loading at the supplier in progress. Grouped by port of loading.</summary>
    public const string AtSupplier = "AtSupplier";

    /// <summary>A Sea leg in progress, or a transshipment between two sea ports. Grouped by movement (the ship).</summary>
    public const string AtSea = "AtSea";

    /// <summary>A Port stay in progress, or its last completed leg ends at a sea port. Grouped by place.</summary>
    public const string AtPort = "AtPort";

    /// <summary>Inland transport, a border crossing or a delivery in progress. Grouped by leg, From → To (a border crossing by its place).</summary>
    public const string OnTheRoad = "OnTheRoad";

    /// <summary>Customs in progress, or its last completed leg ends at a border post or an inland place. Grouped by place.</summary>
    public const string AtBorderCustoms = "AtBorderCustoms";

    /// <summary>Its last completed leg is a Delivery, or a draft goods receipt waits; no goods receipt posted. Grouped by place.</summary>
    public const string Delivered = "Delivered";

    /// <summary>Received lately (only with "Show received"); read-only. Grouped by the warehouse received into.</summary>
    public const string Received = "Received";

    public static readonly string[] All = [AtSupplier, AtSea, AtPort, OnTheRoad, AtBorderCustoms, Delivered, Received];
}

/// <summary>The filters of the board, all on the server (GET api/logistics/shipments/board).</summary>
public sealed class ShipmentBoardQuery
{
    /// <summary>Ref, container no., B/L, vessel (or the truck of the leg in progress), purchase order number.</summary>
    public string? Search { get; init; }

    public int? SupplierId { get; init; }

    /// <summary>Containers carrying lines of this order.</summary>
    public int? PurchaseOrderId { get; init; }

    public int? BranchId { get; init; }

    /// <summary>Where it stands, or the From or the To of the leg carrying it.</summary>
    public int? PlaceId { get; init; }

    /// <summary>"Late only": the leg in progress has an ETA before today.</summary>
    public bool LateOnly { get; init; }

    /// <summary>"With a planned leg": a planned next movement holds it.</summary>
    public bool WithPlannedLeg { get; init; }

    /// <summary>"Show received (30 days)": adds the Received column.</summary>
    public bool ShowReceived { get; init; }
}

/// <summary>A column of the board: its phase, title, and how many containers and pieces it holds after the filters.</summary>
public sealed class ShipmentColumnDto
{
    /// <summary>See <see cref="ShipmentPhases"/>.</summary>
    public string Phase { get; init; } = string.Empty;

    /// <summary>"At supplier", "At sea", "At port", "On the road", "At border / customs", "Delivered, to receive", "Received (30 days)".</summary>
    public string Title { get; init; } = string.Empty;

    public int PhaseOrder { get; init; }
    public int Count { get; init; }
    public long Pieces { get; init; }
}

/// <summary>
/// One card of the board (set 1 of logistics.usp_Shipment_Board). The container's columns carry the names of the
/// Containers list's row (ContainerListDto) - its ship state, next step and proposed leg - so the page uses the same
/// words and the same selection bar for both.
/// <para>
/// ONLY WHAT THE BOARD, ITS LIST AND ITS DRAWER READ. The procedure returns more (the ports, the vessel, the last and the
/// current movement, the proposal's ids and source...); Dapper leaves the columns no property names, and the answer
/// leaves out its empty fields (ShipmentsController): 5,000 open containers were 11.9 MB of JSON, 45% of it nulls, and
/// are 3.6 MB. The drawer reads the container itself for its route.
/// </para>
/// </summary>
public sealed record ShipmentCardDto
{
    public int Id { get; init; }
    public string ContainerRef { get; init; } = string.Empty;

    /// <summary>Null: the badge "No container no.".</summary>
    public string? ContainerNo { get; init; }

    public string ContainerTypeCode { get; init; } = string.Empty;

    /// <summary>1 Draft ... 5 Cleared (6 / 7 received): the badges "Draft" and "Cleared".</summary>
    public byte Status { get; init; }

    /// <summary>The order the container was created from; <see cref="OrderNumbers"/> summarises every order on it.</summary>
    public int? PurchaseOrderId { get; init; }

    public string? PurchaseOrderNumber { get; init; }
    public int OrderCount { get; init; }

    /// <summary>"PO-BR-002-000042 +1".</summary>
    public string? OrderNumbers { get; init; }

    public string? SupplierNames { get; init; }

    /// <summary>"84 pcs TVS-APACHE-160" with one item (<see cref="ItemCode"/>), else "2 items, 120 pcs".</summary>
    public int ItemCount { get; init; }

    /// <summary>The only item's code (null with several items).</summary>
    public string? ItemCode { get; init; }

    /// <summary>The pieces loaded.</summary>
    public int TotalQtyBase { get; init; }

    /// <summary>The tooltip of "Free time over".</summary>
    public DateTime? LastFreeDay { get; init; }

    /* the board */

    /// <summary>Its column (<see cref="ShipmentPhases"/>).</summary>
    public string Phase { get; init; } = string.Empty;

    /// <summary>Its group in the column: an opaque key ("MOV|46", "LEG|4|7", "AT|4", "WH|1").</summary>
    public string GroupKey { get; init; } = string.Empty;

    /// <summary>
    /// The group's words, without its count: "MOV-2026-000046 · MSC Aurora V.123 · Chennai → Dar es Salaam · ETA 20/10/2026",
    /// "Dar es Salaam → Kasumbalesa", "Border crossing at Kasumbalesa", "Chennai", "No port of loading", "Lubumbashi Warehouse".
    /// </summary>
    public string GroupLabel { get; init; } = string.Empty;

    /// <summary>The group's place in its column (1 = first): a ship by its ETA, the others by name, "No ..." last.</summary>
    public int GroupOrder { get; init; }

    /// <summary>Since when it stands where it is: a stay in progress since its start, else the end of the leg that brought it, the delivery, the receipt.</summary>
    public DateTime? AtPlaceSince { get; init; }

    /// <summary>Red "Late": the leg in progress has an ETA before today.</summary>
    public bool IsLate { get; init; }

    /// <summary>
    /// Red "Free time over": at port or cleared and the last free day passed before the end of its Delivery, else before
    /// today - the rule of the container page, the Tracking board and the Dashboard.
    /// </summary>
    public bool IsFreeTimeOver { get; init; }

    /* the shipment (logistics.fn_Container_ShipState): the names of ContainerListDto */

    /// <summary>0: never moved ("Not moved yet").</summary>
    public int MovementCount { get; init; }

    /// <summary>Where its next leg leaves from: "Next leg from {place}…".</summary>
    public string? PlaceName { get; init; }

    public int? ActiveMovementId { get; init; }
    public string? ActiveMovementNo { get; init; }
    public string? ActiveMovementTypeName { get; init; }
    public string? ActiveMovementStage { get; init; }
    public string? ActiveMovementToName { get; init; }
    public DateTime? ActiveMovementEta { get; init; }
    public string? ActiveMovementVehicleOrVessel { get; init; }

    /// <summary>Gray "Planned next: MOV-2026-000051 Inland transport → Kasumbalesa".</summary>
    public int? PlannedMovementId { get; init; }

    public string? PlannedMovementNo { get; init; }
    public string? PlannedMovementTypeName { get; init; }
    public string? PlannedMovementStage { get; init; }
    public string? PlannedMovementToName { get; init; }

    /// <summary>2 in progress, 3 completed; null without a movement (the selection bar's "Select not shipped").</summary>
    public byte? CurrentMovementStatus { get; init; }

    /* its next step (phase 2): the card's "Next step: Arrived at Dar es Salaam…" */

    /// <summary>See <see cref="ContainerNextStepKinds"/>.</summary>
    public string? NextStepKind { get; init; }

    public string? NextStepBlockedReason { get; init; }
    public string? ProposedTypeName { get; init; }
    public string? ProposedStage { get; init; }
    public string? ProposedToName { get; init; }
    public bool? ProposedIsStay { get; init; }

    /* goods receipts: the badge "GRN draft", the number once received */

    public int? GoodsReceiptId { get; init; }
    public string? GoodsReceiptNumber { get; init; }

    /// <summary>1 Draft ("GRN draft"), 2 Posted.</summary>
    public byte? GoodsReceiptStatus { get; init; }
}

/// <summary>The board: its columns (left to right) and every card on it, in the order of the board (column, group, ref).</summary>
public sealed class ShipmentBoardDto
{
    public IReadOnlyList<ShipmentColumnDto> Columns { get; init; } = [];
    public IReadOnlyList<ShipmentCardDto> Containers { get; init; } = [];
}
