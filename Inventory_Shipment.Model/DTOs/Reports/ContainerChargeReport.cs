namespace Inventory_Shipment.Model.DTOs.Reports;

/// <summary>
/// The Container Charges Report's filters (script 105). One date basis at a time: the containers offloaded (received)
/// or dispatched between Date From and Date To, inclusive; no dates = every container not cancelled. At least one charge
/// type: each one asked is a group of columns.
/// </summary>
public sealed class ContainerChargeReportQuery
{
    public int[]? ChargeTypeIds { get; init; }

    /// <summary>Offload (default) | Dispatch.</summary>
    public string? DateBasis { get; init; }

    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }

    /// <summary>Container ref, container no. or B/L.</summary>
    public string? Search { get; init; }

    public int? SupplierId { get; init; }

    /// <summary>All (default) | Entered (every type asked is on the container) | Missing (at least one is not).</summary>
    public string? Entered { get; init; }

    /// <summary>All (default) | Paid (every charge entered is paid) | PartlyPaid | Unpaid (at least one charge so).</summary>
    public string? Payment { get; init; }
}

/// <summary>What the filters offer: the charge types and the suppliers that have containers.</summary>
public sealed class ContainerChargeReportOptions
{
    public IReadOnlyList<ContainerChargeTypeDto> ChargeTypes { get; init; } = [];
    public IReadOnlyList<ContainerChargeSupplierDto> Suppliers { get; init; } = [];
}

public sealed class ContainerChargeTypeDto
{
    public int Id { get; init; }
    public string ChargeCode { get; init; } = string.Empty;
    public string ChargeName { get; init; } = string.Empty;

    /// <summary>A deduction (script 102) is never paid: its payment status is NotPayable.</summary>
    public bool IsDeduction { get; init; }

    public bool IsActive { get; init; } = true;
}

public sealed class ContainerChargeSupplierDto
{
    public int Id { get; init; }
    public string PartyCode { get; init; } = string.Empty;
    public string PartyName { get; init; } = string.Empty;
}

/// <summary>
/// One charge type on one container: every Draft or Posted charge of the type added up (a container may have several
/// freight invoices). <c>Status</c> Entered (one posted at least) | Draft (only drafts) | Missing (none).
/// <c>PaymentStatus</c> Paid | PartlyPaid | Unpaid | NotPayable (a deduction); null when missing or when the reader may
/// not see supplier payments, as are <c>Paid</c> and <c>Balance</c>. Amounts in the base currency.
/// </summary>
public sealed class ContainerChargeCellDto
{
    public string Status { get; init; } = "Missing";
    public int Count { get; init; }
    public decimal? Amount { get; init; }
    public decimal? Paid { get; init; }
    public decimal? Balance { get; init; }
    public string? PaymentStatus { get; init; }

    /// <summary>The charges' own currencies when one is not the base currency ("EUR 1,200.00").</summary>
    public string? Original { get; init; }
}

public sealed class ContainerChargeRowDto
{
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public string? BlNo { get; init; }
    public byte ContainerStatus { get; init; }
    public string? Items { get; init; }
    public int Pieces { get; init; }
    public string? Suppliers { get; init; }
    public string? Orders { get; init; }
    public string? FinalDestination { get; init; }

    /// <summary>The current location as the Container Report groups it (script 100): its sort and its words.</summary>
    public int StageSort { get; init; }

    public string StageLabel { get; init; } = string.Empty;
    public DateOnly? DispatchDate { get; init; }
    public DateOnly? OffloadedDate { get; init; }
    public string? BranchName { get; init; }
    public string? WarehouseName { get; init; }

    /// <summary>Per charge type id asked.</summary>
    public Dictionary<int, ContainerChargeCellDto> Charges { get; init; } = [];

    public decimal Amount { get; init; }
    public decimal? Paid { get; init; }
    public decimal? Balance { get; init; }
}

/// <summary>One charge, for the row's drawer.</summary>
public sealed class ContainerChargeDetailDto
{
    public int ChargeId { get; init; }
    public int ContainerId { get; init; }
    public int ChargeTypeId { get; init; }

    /// <summary>Draft | Posted.</summary>
    public string Status { get; init; } = string.Empty;

    public DateOnly ChargeDate { get; init; }
    public string? Reference { get; init; }
    public string? ProviderName { get; init; }
    public string? CurrencyCode { get; init; }
    public decimal Amount { get; init; }
    public decimal AmountBase { get; init; }
    public decimal? PaidAmount { get; init; }
    public decimal? PaidBase { get; init; }

    /// <summary>"PAY-2026-0031 · 05/11/2026 · 1,200.00; …" (in the charge's currency).</summary>
    public string? Payments { get; init; }

    public string? PaymentStatus { get; init; }
}

public sealed class ContainerChargeTypeTotalsDto
{
    public int Entered { get; init; }
    public int Draft { get; init; }
    public int Missing { get; init; }
    public decimal Amount { get; init; }
    public decimal? Paid { get; init; }
    public decimal? Balance { get; init; }
}

public sealed class ContainerChargeTotalsDto
{
    public int Containers { get; init; }

    /// <summary>The containers with at least one charge type asked missing.</summary>
    public int WithMissing { get; init; }

    public decimal Amount { get; init; }
    public decimal? Paid { get; init; }
    public decimal? Balance { get; init; }
    public Dictionary<int, ContainerChargeTypeTotalsDto> PerType { get; init; } = [];
}

public sealed class ContainerChargeReportResult
{
    public string DateBasis { get; init; } = "Offload";
    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }
    public IReadOnlyList<ContainerChargeTypeDto> ChargeTypes { get; init; } = [];
    public IReadOnlyList<ContainerChargeRowDto> Rows { get; init; } = [];
    public IReadOnlyList<ContainerChargeDetailDto> Charges { get; init; } = [];
    public ContainerChargeTotalsDto Totals { get; init; } = new();

    /// <summary>False without View Supplier Payments: every paid figure and payment status is null.</summary>
    public bool SeesPayments { get; init; }

    public string BaseCurrencyCode { get; init; } = "USD";
    public DateTime GeneratedAtUtc { get; init; }
    public string GeneratedBy { get; init; } = string.Empty;
}
