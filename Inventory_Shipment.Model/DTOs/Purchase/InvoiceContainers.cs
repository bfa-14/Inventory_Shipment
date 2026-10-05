using System.ComponentModel.DataAnnotations;
using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Model.DTOs.Purchase;

/* A purchase invoice "shipped in containers" (script 43): its goods enter the stock at the offload of the containers
   it is linked to. The link is made, undone and completed from the invoice, a container line at a time. */

/// <summary>One item of the invoice: what it needs in containers and what is linked (summary, result set 1).</summary>
public sealed class InvoiceContainerItemDto
{
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public int InvoicedBase { get; init; }

    /// <summary>The item's Container unit (pieces in a full container); null when it has none.</summary>
    public int? PcsPerContainer { get; init; }

    /// <summary>Invoiced / pieces per container, 2 decimals: 2.50 = 2 full containers + 42 pieces of an 84-piece item.</summary>
    public decimal? ContainersNeeded { get; init; }

    public int? FullContainers { get; init; }
    public int? PartialPieces { get; init; }
    public int LinkedBase { get; init; }

    /// <summary>The distinct containers the item's linked pieces are on.</summary>
    public int ContainersLinked { get; init; }

    public int UnlinkedBase { get; init; }
}

/// <summary>A container the invoice is linked to, per item (summary, result set 2).</summary>
public sealed class InvoiceLinkedContainerDto
{
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public byte Status { get; init; }
    public string StatusName => ContainerStatus.Name(Status);
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;

    /// <summary>The invoice's pieces of that item on the container.</summary>
    public int QuantityBase { get; init; }

    /// <summary>(50) The item's pieces in a full container (its Container unit); null when it has none.</summary>
    public int? PcsPerContainer { get; init; }

    /// <summary>QuantityBase / the item's pieces per container, in % (script 50; it was the container's Max units).</summary>
    public decimal? ShareOfContainerPct { get; init; }

    /// <summary>Only a Draft or Confirmed container can still be unlinked.</summary>
    public bool CanUnlink { get; init; }
}

public sealed class InvoiceContainerSummaryDto
{
    public IReadOnlyList<InvoiceContainerItemDto> Items { get; init; } = [];
    public IReadOnlyList<InvoiceLinkedContainerDto> Containers { get; init; } = [];

    /// <summary>What the invoice can do with containers now, and why not (script 47). Set on every answer of the API.</summary>
    public InvoiceContainerStateDto? State { get; init; }
}

/// <summary>
/// What a purchase invoice can do with containers now (purchase.usp_PurchaseInvoice_ContainerState, script 47). The
/// rules: 1 a purchase invoice, draft or posted; 2 created from a purchase order; 3 one item (a draft); 4 shipped in
/// containers; 5 its order approved, or closed; 6 pieces not in a container; 7 the order lines still allow pieces; 8 a
/// new container of at most MaxAddQty pieces; 9 the caller's permissions. Reason is the first rule that fails, in the
/// words the add and the link refuse with - the page shows it, it never has to guess.
/// </summary>
public sealed class InvoiceContainerStateDto
{
    public bool CanAddContainers { get; init; }
    public string? Reason { get; init; }

    /// <summary>1-9; null when every rule holds.</summary>
    public byte? FailedRule { get; init; }

    /// <summary>A draft with "Shipped in containers" off that may turn it on: the save of the invoice with the switch.</summary>
    public bool CanTurnOnShipped { get; init; }

    public int NotInContainerQty { get; init; }

    /// <summary>What the invoice's order lines still allow: ordered - invoiced outside containers - loaded in containers.</summary>
    public int OrderLinesAvailableQty { get; init; }

    /// <summary>The most a new container may take: per order line the lesser of the two above.</summary>
    public int MaxAddQty { get; init; }

    /// <summary>The item's Container unit; null when it has none.</summary>
    public int? PcsPerContainer { get; init; }

    public bool CanLink { get; init; }
    public string? LinkReason { get; init; }
}

/// <summary>A container line the invoice can be linked to: of its order, Draft or Confirmed, with something not invoiced.</summary>
public sealed class InvoiceLinkCandidateDto
{
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public byte ContainerStatus { get; init; }
    public string ContainerStatusName => Logistics.ContainerStatus.Name(ContainerStatus);
    public int ContainerLineId { get; init; }
    public int ContainerLineNumber { get; init; }
    public int PoLineId { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public int LoadedBase { get; init; }

    /// <summary>By every invoice that is not cancelled, this one included.</summary>
    public int InvoicedBase { get; init; }

    public int AvailableBase { get; init; }

    /// <summary>The invoice's pieces of that order line outside containers: the most that can be linked here.</summary>
    public int UnlinkedBase { get; init; }
}

public sealed class LinkInvoiceContainersRequest
{
    /// <summary>The invoice's, as the page last read it.</summary>
    public string? RowVersion { get; init; }

    [MinLength(1)]
    public IReadOnlyList<ContainerLineQuantityRequest> Links { get; init; } = [];
}

/// <summary>
/// "Add container" from an invoice: the Add Container fields of the order, and how many of the invoice's pieces go in.
/// The container is created on the invoice's order and linked to the invoice in one transaction.
/// </summary>
public sealed class AddInvoiceContainerRequest
{
    /// <summary>The invoice's, as the page last read it.</summary>
    public string? RowVersion { get; init; }

    /// <summary>The pieces of the invoice to put in the container: at most what it has outside containers.</summary>
    [Range(1, int.MaxValue)]
    public int QuantityBase { get; init; }

    /// <summary>The item of the invoice; null = its only item with pieces outside containers.</summary>
    [Range(1, int.MaxValue)]
    public int? ItemId { get; init; }

    /// <summary>As on the order's Add Container form: the item's oil travels with it.</summary>
    public bool OilIncluded { get; init; }

    /// <summary>Null = the item's value (when oil is included).</summary>
    [Range(0, 9999999.99)]
    public decimal? OilQtyPerUnit { get; init; }

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

    /// <summary>Null = today.</summary>
    public DateOnly? OrderDate { get; init; }

    /// <summary>Sea, Air or Road; null = Sea.</summary>
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

    /* maxUnits from an older page is ignored (an unknown member): the capacity is the items' Container units. */

    /// <summary>Null = the invoice's branch.</summary>
    public int? BranchId { get; init; }

    /// <summary>The offloading destination; null = the invoice's warehouse.</summary>
    public int? WarehouseId { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    /// <summary>The caller confirmed a load above capacity. Needs containers.overcapacity.</summary>
    public bool AllowOverCapacity { get; init; }
}

/// <summary>The auto-plan proposal of an invoice: the order's, for the pieces the invoice has outside containers.</summary>
public sealed class InvoiceAutoPlanRequest
{
    [Range(1, int.MaxValue)]
    public int ContainerTypeId { get; init; }

    /// <summary>False = the rest of every order line gets its own container.</summary>
    public bool MixRemainders { get; init; } = true;

    public IReadOnlyList<ItemCapacityRequest>? Capacities { get; init; }
}

/// <summary>The proposal of an invoice, created on its order and linked to it in one transaction.</summary>
public sealed class InvoiceContainersFromPlanRequest
{
    /// <summary>The invoice's, as the page last read it.</summary>
    public string? RowVersion { get; init; }

    [Range(1, int.MaxValue)]
    public int ContainerTypeId { get; init; }

    /// <summary>Null = today.</summary>
    public DateOnly? OrderDate { get; init; }

    /// <summary>Null = the order's branch.</summary>
    public int? BranchId { get; init; }

    /// <summary>The offloading destination; null = the order's warehouse.</summary>
    public int? WarehouseId { get; init; }

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
    public bool AllowOverCapacity { get; init; }
    public bool Confirm { get; init; }
}

/// <summary>What adding containers from an invoice created, and the invoice's containers after the link.</summary>
public sealed class InvoiceContainersCreatedDto
{
    public IReadOnlyList<CreatedContainerDto> Created { get; init; } = [];
    public InvoiceContainerSummaryDto Summary { get; init; } = new();
}
