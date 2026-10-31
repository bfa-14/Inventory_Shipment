namespace Inventory_Shipment.Model.DTOs.Logistics;

/// <summary>
/// Reports › Container Report (script 95): every container line and every approved order line still to load, with its
/// order, invoices, payments, journey, charges and cost, grouped by where the goods are now (<see cref="StageLabel"/>).
///
/// AMOUNTS ARE IN THE BASE CURRENCY. A figure the reader may not see is null, never 0: the charges without View Container
/// Charges, the payments without View Supplier Payments.
/// </summary>
public sealed class ContainerReportRowDto
{
    /// <summary>"C{container line id}" or "P{order line id}" (an order line still to load). Stable; the page's row id.</summary>
    public string RowKey { get; init; } = string.Empty;

    /// <summary>An approved order line with pieces still to load: no container yet.</summary>
    public bool IsPending { get; init; }

    /// <summary>The order of the stages, the way the tracking sheet reads: pending (newest month first) … offloaded.</summary>
    public decimal StageSort { get; init; }

    /// <summary>"Order pending - November 2026", "In transit India → Dar es Salaam", "Dar es Salaam → Mokambo", "Offloaded in Lubumbashi".</summary>
    public string StageLabel { get; init; } = string.Empty;

    public DateTime OrderDate { get; init; }
    public int PurchaseOrderId { get; init; }
    public string? PoNumber { get; init; }

    /// <summary>"Sep-25": the container's order month, else the order date's.</summary>
    public string? OrderMonth { get; init; }

    /// <summary>The first posted supplier invoice's date; <see cref="InvoiceDates"/> lists them all.</summary>
    public DateTime? InvoiceDate { get; init; }
    public string? InvoiceDates { get; init; }
    public string? InvoiceNumbers { get; init; }
    public string? CommercialInvoiceNos { get; init; }
    public string? ExporterReferences { get; init; }

    public int? ContainerId { get; init; }
    public string? ContainerRef { get; init; }
    public string? ContainerNo { get; init; }
    public byte? ContainerStatus { get; init; }

    /// <summary>Draft, Confirmed, In Transit, At Port, Cleared, Offloaded, Closed; "Not loaded" for an order line still to load.</summary>
    public string StatusName { get; set; } = string.Empty;

    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;

    /// <summary>The item's name: the sheet's MODEL.</summary>
    public string Model { get; init; } = string.Empty;

    public int Quantity { get; init; }

    /// <summary>The order's supplier reference: the PI number.</summary>
    public string? PiNumber { get; init; }

    public int SupplierId { get; init; }
    public string? SupplierName { get; init; }
    public string? BranchName { get; init; }
    public string? WarehouseCode { get; init; }

    /// <summary>Pieces × the FOB per piece: the invoice price once received, else the container page's estimate (or the order price).</summary>
    public decimal? FobAmountBase { get; init; }
    public bool FobIsEstimate { get; init; }
    public decimal? OilQtyPerUnit { get; init; }

    public string? PaidDates { get; set; }
    public string? PaymentReferences { get; set; }

    /// <summary>Paid, Partly paid, Not paid, Not invoiced.</summary>
    public string? PaymentStatus { get; set; }

    public DateTime? DispatchDate { get; init; }
    public DateTime? ArrivedPortDate { get; init; }
    public DateTime? LeftPortDate { get; init; }

    /// <summary>The places the legs after the port went to, in order ("Mokambo → Lubumbashi").</summary>
    public string? FinalDestination { get; init; }

    public string? Trucks { get; init; }
    public DateTime? OffloadedDate { get; init; }
    public string? GoodsReceiptNumbers { get; init; }

    /// <summary>(Offloaded - order date) / 30 days; before the offload, up to today (<see cref="LeadTimeSoFar"/>).</summary>
    public decimal? LeadTimeMonths { get; init; }
    public bool LeadTimeSoFar { get; init; }

    public string? BlNo { get; init; }
    public string? FeriNo { get; init; }

    /// <summary>The references of the container's posted transport charges (Freight / Shipping, Inland Transportation).</summary>
    public string? TransportReferences { get; set; }

    /// <summary>"05/11/2025 · 2500323 · 10,000.00; 23/12/2025 · 2500961 · 6,100.00": the container's transport invoices.</summary>
    public string? TransportInvoices { get; set; }

    /// <summary>This line's share of the transport charges.</summary>
    public decimal? TransportBase { get; set; }

    /// <summary>This line's share of every posted charge.</summary>
    public decimal? ChargesBase { get; set; }

    /// <summary>This line's share of the posted charges, per charge type id.</summary>
    public Dictionary<int, decimal>? Charges { get; set; }

    /// <summary>FOB + charges.</summary>
    public decimal? TotalExpensesBase { get; init; }

    /// <summary>The landed cost per piece: final once received (<see cref="CostIsEstimate"/> false), else an estimate.</summary>
    public decimal? CostPerUnitBase { get; init; }
    public bool CostIsEstimate { get; init; }

    public bool IsLate { get; init; }
    public bool IsFreeTimeOver { get; init; }

    /// <summary>Late, Free time over, Not invoiced, Not paid, Partly paid, No container no., No B/L.</summary>
    public IReadOnlyList<string> Alerts { get; set; } = [];
}

public sealed class ContainerReportChargeTypeDto
{
    public int Id { get; init; }
    public string ChargeCode { get; init; } = string.Empty;
    public string ChargeName { get; init; } = string.Empty;

    /// <summary>Freight / Shipping or Inland Transportation: summed into TOTAL TRANSPORT AMOUNT, not a column of its own.</summary>
    public bool IsTransport { get; init; }
}

public sealed class ContainerReportResult
{
    public IReadOnlyList<ContainerReportRowDto> Rows { get; init; } = [];

    /// <summary>The charge types with an amount in the rows, other than the transport ones: one column each.</summary>
    public IReadOnlyList<ContainerReportChargeTypeDto> ChargeTypes { get; init; } = [];

    /// <summary>False without View Container Charges: the charge columns are left out.</summary>
    public bool ChargesVisible { get; init; }

    /// <summary>False without View Supplier Payments: the payment columns are left out.</summary>
    public bool PaymentsVisible { get; init; }
}

public sealed class ContainerReportQuery
{
    /// <summary>Container ref or number, B/L, order number, PI number, invoice number.</summary>
    public string? Search { get; init; }

    public int? SupplierId { get; init; }
    public int? ItemId { get; init; }
    public int? ItemFamilyId { get; init; }
    public int? BranchId { get; init; }
    public DateOnly? OrderDateFrom { get; init; }
    public DateOnly? OrderDateTo { get; init; }

    /// <summary>Narrow the received containers only; the others are always shown.</summary>
    public DateOnly? OffloadedFrom { get; init; }
    public DateOnly? OffloadedTo { get; init; }

    public bool IncludePending { get; init; } = true;
    public bool IncludeReceived { get; init; } = true;
}
