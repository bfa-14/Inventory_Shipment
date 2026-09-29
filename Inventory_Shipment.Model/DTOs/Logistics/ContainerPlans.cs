using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Logistics;

/* ── auto-plan: the proposal (logistics.usp_Container_PlanFromOrder, nothing saved) ────────────── */

/// <summary>Pieces of one item in a full container, as typed in the dialog (logistics.tvp_ItemCapacity).</summary>
public sealed class ItemCapacityRequest
{
    public int ItemId { get; init; }
    public int PcsPerContainer { get; init; }
}

public sealed class AutoPlanRequest
{
    [Range(1, int.MaxValue)]
    public int PurchaseOrderId { get; init; }

    [Range(1, int.MaxValue)]
    public int ContainerTypeId { get; init; }

    /// <summary>False = the rest of every order line gets its own container.</summary>
    public bool MixRemainders { get; init; } = true;

    /// <summary>Items left out take the item's container unit, else the container type's capacity.</summary>
    public IReadOnlyList<ItemCapacityRequest>? Capacities { get; init; }
}

/// <summary>One proposed container (result set 1).</summary>
public sealed class PlannedContainerDto
{
    public int Seq { get; init; }
    public int ItemCount { get; init; }
    public int Units { get; init; }

    /// <summary>Sum of quantity / pieces per container, in % (one decimal); null when an item has no capacity.</summary>
    public decimal? FillPct { get; init; }

    /// <summary>The equivalent capacity in pieces: 84 for a full container of an 84-piece item, 102 for 42 x 84 + 60 x 120.</summary>
    public int? MaxUnits { get; init; }

    /// <summary>The item code, or "Mixed - 2 items".</summary>
    public string ItemSummary { get; init; } = string.Empty;
}

/// <summary>One line of a proposed container (result set 2).</summary>
public sealed class PlannedContainerLineDto
{
    public int Seq { get; init; }
    public int LineNumber { get; init; }
    public int PoLineId { get; init; }
    public int PoLineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string? Model { get; init; }
    public int QuantityBase { get; init; }
    public int? PcsPerContainer { get; init; }
    public bool OilIncluded { get; init; }
    public decimal? OilQtyPerUnit { get; init; }
}

/// <summary>One line of the order (result set 3): what can still be loaded and what the plan loads.</summary>
public sealed class PlanOrderLineDto
{
    public int PoLineId { get; init; }
    public int PoLineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public string? Model { get; init; }
    public int OrderedBase { get; init; }
    public int AvailableBase { get; init; }
    public int PlannedBase { get; init; }
    public int? PcsPerContainer { get; init; }

    /// <summary>Where <see cref="PcsPerContainer"/> comes from: Entered, Item (its container unit), Type or None.</summary>
    public string CapacitySource { get; init; } = string.Empty;

    public decimal ContainersNeeded { get; init; }
    public bool OilIncluded { get; init; }
}

public sealed class AutoPlanDto
{
    public IReadOnlyList<PlannedContainerDto> Containers { get; init; } = [];
    public IReadOnlyList<PlannedContainerLineDto> Lines { get; init; } = [];
    public IReadOnlyList<PlanOrderLineDto> OrderLines { get; init; } = [];
}

/* ── auto-plan: creating the (edited) plan (logistics.usp_Container_CreateBatch) ─────────────── */

public sealed class PlanLineRequest
{
    public int PoLineId { get; init; }

    /// <summary>Pieces (base units).</summary>
    public int QuantityBase { get; init; }

    /// <summary>Null = yes when the item has an oil quantity per unit.</summary>
    public bool? OilIncluded { get; init; }
}

public sealed class PlanContainerRequest
{
    /// <summary>1..N in the order shown to the user: an error names "Container &lt;seq&gt; of &lt;N&gt;".</summary>
    public int Seq { get; init; }

    public IReadOnlyList<PlanLineRequest> Lines { get; init; } = [];
}

/// <summary>
/// Every container gets the same header. Send the SAME capacities as the proposal: the procedure
/// recomputes each container's Max units from them (without them an 84-piece item would get the
/// container type's capacity).
/// </summary>
public sealed class CreateContainersFromPlanRequest
{
    [Range(1, int.MaxValue)]
    public int PurchaseOrderId { get; init; }

    [Range(1, int.MaxValue)]
    public int ContainerTypeId { get; init; }

    /// <summary>Null = today.</summary>
    public DateOnly? OrderDate { get; init; }

    /// <summary>Null = the order's branch.</summary>
    public int? BranchId { get; init; }

    /// <summary>The offloading destination; null = the order's warehouse.</summary>
    public int? WarehouseId { get; init; }

    /// <summary>Sea, Air or Road; null = Sea.</summary>
    [StringLength(10)]
    public string? ShippingMethod { get; init; }

    [StringLength(2, MinimumLength = 2)]
    public string? CountryOfOrigin { get; init; }

    public int? ForwarderId { get; init; }

    [StringLength(100)]
    public string? ShippingLine { get; init; }

    public int? PortOfLoadingId { get; init; }
    public int? PortOfDestinationId { get; init; }
    public int? FinalDestinationId { get; init; }
    public DateOnly? Eta { get; init; }

    [Range(0, 3650)]
    public int? FreeDays { get; init; }

    public IReadOnlyList<PlanContainerRequest> Containers { get; init; } = [];
    public IReadOnlyList<ItemCapacityRequest>? Capacities { get; init; }

    /// <summary>The caller confirmed containers above capacity. Needs containers.overcapacity.</summary>
    public bool AllowOverCapacity { get; init; }

    /// <summary>Confirm the new containers at once. Needs containers.confirm.</summary>
    public bool Confirm { get; init; }
}

/// <summary>A container created from the plan.</summary>
public sealed class CreatedContainerDto
{
    public int Seq { get; init; }
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public byte Status { get; init; }
    public int TotalLines { get; init; }
    public int TotalAllocatedBase { get; init; }
    public int? MaxUnits { get; init; }
    public decimal? UtilizationPct { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

/* ── bulk actions on selected containers ──────────────────────────────────────────────────── */

public sealed class ContainerNumberRequest
{
    public int ContainerId { get; init; }

    /// <summary>Always sent: empty clears it. Trimmed, upper-cased by the procedure, at most 20 characters.</summary>
    public string? ContainerNo { get; init; }

    /// <summary>Always sent: empty clears it. Trimmed, at most 30 characters.</summary>
    public string? SealNo { get; init; }
}

public sealed class ContainerNumbersRequest
{
    public IReadOnlyList<ContainerNumberRequest> Items { get; init; } = [];
}

public sealed class ContainerNumberDto
{
    public int Id { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public string? SealNo { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

/// <summary>The selected containers (bulk confirm, bulk delete).</summary>
public sealed class IdsRequest
{
    public IReadOnlyList<int> Ids { get; init; } = [];
}

public sealed class ContainerConfirmedDto
{
    public int Id { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public byte Status { get; init; }

    /// <summary>False when it was no longer a draft (left as it was).</summary>
    public bool ConfirmedNow { get; init; }

    public byte[] RowVersion { get; init; } = [];
}

public sealed class ContainersDeletedDto
{
    public int Deleted { get; init; }
}
