using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Logistics;

/* Container charges (script 27): freight, clearing, insurance... always per container, optionally
   linked to the movement that caused them, in any currency. Draft → Posted (locked) → Cancelled.
   Only posted charges whose type enters the landed cost reach the cost of the items; one posted
   after the offload becomes a cost adjustment (inventory.CostAdjustments, SourceKind CNTCHARGE). */

/// <summary>Draft → Posted → Cancelled.</summary>
public static class ContainerChargeStatus
{
    public const byte Draft = 1;
    public const byte Posted = 2;
    public const byte Cancelled = 3;

    private static readonly string[] Names = ["Draft", "Posted", "Cancelled"];

    public static string Name(byte status)
        => status is >= Draft and <= Cancelled ? Names[status - 1] : "Unknown";

    /// <summary>The code 1–3 or the name; null when neither.</summary>
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

        var index = Array.FindIndex(Names, n => string.Equals(n, status.Trim(), StringComparison.OrdinalIgnoreCase));
        return index >= 0 ? (byte)(index + 1) : null;
    }
}

/// <summary>How one total typed for several containers is split between them.</summary>
public static class ChargeSplitRules
{
    /// <summary>Each container gets the whole amount.</summary>
    public const string Same = "Same";

    public const string Equal = "Equal";

    /// <summary>By the pieces loaded (the default).</summary>
    public const string Pieces = "Pieces";

    /// <summary>By the FOB value loaded.</summary>
    public const string Value = "Value";

    public static readonly string[] All = [Same, Equal, Pieces, Value];

    public static string? Normalize(string? rule)
        => All.FirstOrDefault(r => string.Equals(r, rule, StringComparison.OrdinalIgnoreCase));
}

/// <summary>How a charge is divided over the lines of its container.</summary>
public static class ContainerChargeMethods
{
    public static readonly string[] All = ["Value", "Quantity", "Weight", "Volume", "Manual"];

    public static string? Normalize(string? method)
        => All.FirstOrDefault(m => string.Equals(m, method, StringComparison.OrdinalIgnoreCase));
}

/// <summary>
/// What a charge's status — and its container's — allows. A closed container is reopened before a
/// late charge is added or changed; the permission is checked separately.
/// </summary>
public abstract record ContainerChargeFlags
{
    public byte Status { get; init; }
    public string StatusName => ContainerChargeStatus.Name(Status);

    /// <summary>The container's status (see <see cref="Logistics.ContainerStatus"/>).</summary>
    public byte ContainerStatus { get; init; }

    public bool CanEdit => Status == ContainerChargeStatus.Draft && ContainerOpen;
    public bool CanDelete => Status == ContainerChargeStatus.Draft && ContainerOpen;
    public bool CanPost => Status == ContainerChargeStatus.Draft && ContainerOpen;
    public bool CanCancel => Status == ContainerChargeStatus.Posted && ContainerStatus != Logistics.ContainerStatus.Closed;

    /// <summary>"Apply to other containers": a draft or posted charge whose container is still open.</summary>
    public bool CanCopy => Status is ContainerChargeStatus.Draft or ContainerChargeStatus.Posted && ContainerOpen;

    private bool ContainerOpen
        => ContainerStatus is not (Logistics.ContainerStatus.Closed or Logistics.ContainerStatus.Cancelled);
}

/// <summary>One row of the container charge list (logistics.usp_ContainerCharge_Search).</summary>
public record ContainerChargeListDto : ContainerChargeFlags
{
    public int Id { get; init; }
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
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
    public bool AppliedAtOffload { get; init; }

    /// <summary>Posted (or cancelled) after the offload: written as a cost adjustment.</summary>
    public bool AdjustedAfterOffload { get; init; }

    public int AttachmentCount { get; init; }
    public DateTime? PostedAtUtc { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public byte[] RowVersion { get; init; } = [];

    /* (47) Supplier payments - posted charges only; null otherwise. */
    public decimal? PaidAmount { get; init; }
    public decimal? OutstandingAmount { get; init; }

    /// <summary>Unpaid, Partial or Paid.</summary>
    public string? PaymentStatus { get; init; }
}

/// <summary>The charge list: one page, and the total (base) of the WHOLE filter.</summary>
public sealed class ContainerChargePageDto
{
    public IReadOnlyList<ContainerChargeListDto> Items { get; init; } = [];
    public int Page { get; init; }
    public int PageSize { get; init; }
    public int TotalCount { get; init; }
    public int TotalPages => PageSize <= 0 ? 0 : (int)Math.Ceiling(TotalCount / (double)PageSize);

    /// <summary>Sum of AmountBase over every row of the filter, not only this page.</summary>
    public decimal TotalAmountBase { get; init; }
}

/// <summary>A charge's share of one container line (set 2 of usp_ContainerCharge_Get): the real cost per item.</summary>
public sealed class ContainerChargeShareDto
{
    public int ContainerLineId { get; init; }
    public int LineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;

    /// <summary>Received once offloaded, loaded before.</summary>
    public int QuantityBase { get; init; }

    public decimal? Basis { get; init; }
    public decimal AmountBase { get; init; }
    public bool IsManual { get; init; }
    public decimal? PerUnitBase { get; init; }
}

/// <summary>A document attached to the charge (set 3) — the provider's invoice, typically.</summary>
public sealed class ContainerChargeAttachmentDto
{
    public int Id { get; init; }
    public int ContainerId { get; init; }
    public int? MovementId { get; init; }
    public int? AttachmentTypeId { get; init; }
    public string? Category { get; init; }
    public string? SubType { get; init; }
    public int FileId { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public int SizeBytes { get; init; }
    public string? Note { get; init; }
    public DateTime? DocumentDate { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
}

/// <summary>
/// A charge of the same group on another container (set 4) — and the shape of the rows
/// usp_ContainerCharge_Create answers with: one draft per container.
/// </summary>
public sealed class ContainerChargeGroupMemberDto
{
    public int Id { get; init; }
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public Guid? GroupId { get; init; }
    public decimal Amount { get; init; }
    public decimal AmountBase { get; init; }
    public byte Status { get; init; }
    public string StatusName => ContainerChargeStatus.Name(Status);
    public byte[] RowVersion { get; init; } = [];
}

/// <summary>A charge with its split over the items, its documents and its group — the four sets of usp_ContainerCharge_Get.</summary>
public sealed record ContainerChargeDto : ContainerChargeFlags
{
    public int Id { get; init; }
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public int? MovementId { get; init; }
    public string? MovementNo { get; init; }
    public Guid? GroupId { get; init; }
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
    public string AllocationMethod { get; init; } = string.Empty;
    public bool IncludeInLandedCost { get; init; }
    public bool AppliedAtOffload { get; init; }
    public bool AdjustedAfterOffload { get; init; }
    public string? Notes { get; init; }
    public DateTime? PostedAtUtc { get; init; }
    public string? PostedByName { get; init; }
    public DateTime? CancelledAtUtc { get; init; }
    public string? CancelledByName { get; init; }
    public string? CancelReason { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public string? UpdatedByName { get; init; }
    public byte[] RowVersion { get; init; } = [];

    /* (47) Supplier payments - posted charges only; null otherwise. */
    public decimal? PaidAmount { get; init; }
    public decimal? OutstandingAmount { get; init; }

    /// <summary>Unpaid, Partial or Paid.</summary>
    public string? PaymentStatus { get; init; }

    /// <summary>Every line of the container, with this charge's share (0 when it took none).</summary>
    public IReadOnlyList<ContainerChargeShareDto> Allocations { get; init; } = [];

    public IReadOnlyList<ContainerChargeAttachmentDto> Attachments { get; init; } = [];

    /// <summary>The same charge on the other containers of the group.</summary>
    public IReadOnlyList<ContainerChargeGroupMemberDto> Group { get; init; } = [];
}

/* ── requests ──────────────────────────────────────────────────────────────────────────────── */

/// <summary>One charge typed for one or several containers: one DRAFT per container, same GroupId when several.</summary>
public sealed class CreateContainerChargeRequest : IValidatableObject
{
    /// <summary>At least one. With a movement, every container must travel with it.</summary>
    public IReadOnlyList<int> ContainerIds { get; init; } = [];

    public int? MovementId { get; init; }

    [Range(1, int.MaxValue)]
    public int ChargeTypeId { get; init; }

    [StringLength(200)]
    public string? Description { get; init; }

    public int? ProviderPartyId { get; init; }

    [StringLength(100)]
    public string? Reference { get; init; }

    [Required]
    public DateOnly ChargeDate { get; init; }

    /// <summary>Null = the base currency.</summary>
    public int? CurrencyId { get; init; }

    /// <summary>Null = 1 (official).</summary>
    [Range(1, 3)]
    public byte? RateType { get; init; }

    /// <summary>Null = the rate of the charge date.</summary>
    [Range(0.000001, double.MaxValue)]
    public decimal? ExchangeRate { get; init; }

    [Range(0.01, 9999999999999999.99)]
    public decimal TotalAmount { get; init; }

    /// <summary>Same | Equal | Pieces (default) | Value.</summary>
    [StringLength(10)]
    public string SplitRule { get; init; } = ChargeSplitRules.Pieces;

    /// <summary>Null = the charge type's method.</summary>
    [StringLength(10)]
    public string? AllocationMethod { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }

    public IEnumerable<ValidationResult> Validate(ValidationContext validationContext)
    {
        if (ContainerIds.Count == 0)
        {
            yield return new ValidationResult("Select at least one container.", [nameof(ContainerIds)]);
        }

        if (ChargeSplitRules.Normalize(SplitRule) is null)
        {
            yield return new ValidationResult("Split rule must be Same, Equal, Pieces or Value.", [nameof(SplitRule)]);
        }

        if (AllocationMethod is not null && ContainerChargeMethods.Normalize(AllocationMethod) is null)
        {
            yield return new ValidationResult(
                "Allocation method must be Value, Quantity, Weight, Volume or Manual.", [nameof(AllocationMethod)]);
        }
    }
}

/// <summary>A manual share of a charge on one container line, in the base currency.</summary>
public sealed class ChargeManualShareRequest
{
    [Range(1, int.MaxValue)]
    public int ContainerLineId { get; init; }

    [Range(0, 9999999999999999.99)]
    public decimal AmountBase { get; init; }
}

/// <summary>One DRAFT charge. manual[] is used when the method is Manual: the shares must add up to the amount.</summary>
public sealed class UpdateContainerChargeRequest : IValidatableObject
{
    public int? MovementId { get; init; }

    [Range(1, int.MaxValue)]
    public int ChargeTypeId { get; init; }

    [StringLength(200)]
    public string? Description { get; init; }

    public int? ProviderPartyId { get; init; }

    [StringLength(100)]
    public string? Reference { get; init; }

    [Required]
    public DateOnly ChargeDate { get; init; }

    public int? CurrencyId { get; init; }

    [Range(1, 3)]
    public byte? RateType { get; init; }

    [Range(0.000001, double.MaxValue)]
    public decimal? ExchangeRate { get; init; }

    [Range(0.01, 9999999999999999.99)]
    public decimal Amount { get; init; }

    [StringLength(10)]
    public string? AllocationMethod { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }

    public IReadOnlyList<ChargeManualShareRequest> Manual { get; init; } = [];

    public string? RowVersion { get; init; }

    public IEnumerable<ValidationResult> Validate(ValidationContext validationContext)
    {
        if (AllocationMethod is not null && ContainerChargeMethods.Normalize(AllocationMethod) is null)
        {
            yield return new ValidationResult(
                "Allocation method must be Value, Quantity, Weight, Volume or Manual.", [nameof(AllocationMethod)]);
        }

        if (Manual.GroupBy(m => m.ContainerLineId).FirstOrDefault(g => g.Count() > 1) is { } twice)
        {
            yield return new ValidationResult($"Container line {twice.Key} appears more than once.", [nameof(Manual)]);
        }
    }
}

/// <summary>Several drafts posted together: all or nothing.</summary>
public sealed class PostChargesRequest
{
    public IReadOnlyList<int> Ids { get; init; } = [];
}

/// <summary>Posting one charge carries the version the caller saw.</summary>
public sealed class ChargeActionRequest
{
    public string? RowVersion { get; init; }
}

/* ── a charge copied to other containers ──────────────────────────────────────────────────── */

public sealed class ChargeCopyCandidateQuery
{
    /// <summary>Container ref or no. (contains).</summary>
    public string? Search { get; init; }

    /// <summary>Only the containers of the original's purchase order.</summary>
    public bool SameOrder { get; init; } = true;
}

/// <summary>A container that can receive a copy of the charge (logistics.usp_ContainerCharge_CopyCandidates): not closed, not cancelled.</summary>
public sealed class ChargeCopyCandidateDto
{
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public string ContainerTypeCode { get; init; } = string.Empty;
    public byte Status { get; init; }
    public string? CurrentLocation { get; init; }
    public int? PurchaseOrderId { get; init; }
    public string? PurchaseOrderNumber { get; init; }
    public int TotalAllocatedBase { get; init; }
    public string? ItemSummary { get; init; }

    /// <summary>The original's container.</summary>
    public bool IsSource { get; init; }

    /// <summary>The original's container, or one already carrying a (not cancelled) charge of the same group.</summary>
    public bool HasThisCharge { get; init; }
}

/// <summary>
/// One DRAFT per container in the same group as the original: same type, provider, reference,
/// currency and rate. Null values = the original's (a Manual original gives the charge type's method).
/// </summary>
public sealed class CopyContainerChargeRequest
{
    /// <summary>At least one other container.</summary>
    public IReadOnlyList<int> ContainerIds { get; init; } = [];

    /// <summary>Per container, in the charge's currency.</summary>
    [Range(0, 9999999999999999.99)]
    public decimal? Amount { get; init; }

    public DateOnly? ChargeDate { get; init; }

    /// <summary>Value, Quantity, Weight or Volume.</summary>
    [StringLength(10)]
    public string? AllocationMethod { get; init; }

    /// <summary>Post the copies at once. Needs containers.charges.post.</summary>
    public bool Post { get; init; }
}

/// <summary>A charge created by the copy.</summary>
public sealed class CopiedContainerChargeDto
{
    public int Id { get; init; }
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public Guid? GroupId { get; init; }
    public decimal Amount { get; init; }
    public decimal AmountBase { get; init; }
    public string AllocationMethod { get; init; } = string.Empty;
    public byte Status { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

public sealed class ContainerChargeQuery
{
    /// <summary>Container ref / no., reference, description or provider (contains).</summary>
    public string? Search { get; init; }

    public int? ContainerId { get; init; }
    public int? MovementId { get; init; }
    public int? ChargeTypeId { get; init; }
    public int? ProviderPartyId { get; init; }

    /// <summary>The code 1–3 or the name (Draft, Posted, Cancelled).</summary>
    public string? Status { get; init; }

    /// <summary>Charge date range.</summary>
    public DateOnly? DateFrom { get; init; }

    public DateOnly? DateTo { get; init; }

    /// <summary>ChargeDate, ContainerRef, ChargeName, AmountBase, Status or CreatedAtUtc.</summary>
    public string SortBy { get; init; } = "ChargeDate";

    public string SortDir { get; init; } = "desc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}
