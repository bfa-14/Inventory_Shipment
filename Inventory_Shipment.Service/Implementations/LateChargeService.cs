using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Late charges: the landed cost adjustments of one invoice, edited a charge at a time.
///
/// ONE CHARGE IS CHANGED BY RE-SAVING THE DRAFT. usp_LandedCostAdjustment_Save replaces a draft's
/// whole list, so adding, changing or removing one charge sends the draft's other charges back as
/// they were stored — currency, method and the RATE they were converted at, so moving the draft's date
/// re-converts only the charge being saved. Their ids change with every save; the responses carry the
/// fresh list. The draft's row version from the read goes with the save, so a charge somebody else
/// added in between is refused (67004) rather than dropped.
///
/// READS GO TO THE REPOSITORIES. The endpoint's own permission is checked here; the writes then pass
/// through <see cref="ILandedCostAdjustmentService"/>, which checks its own again.
/// </summary>
public sealed class LateChargeService : ILateChargeService
{
    private const string ForbiddenCode = "FORBIDDEN";

    /// <summary>The text of usp_LandedCostAdjustment_Save's THROW 67012: the reads must say it too, and in the same words.</summary>
    private const string ImportedInvoiceMessage =
        "This invoice comes from containers: late charges are entered on the containers (Container Charges), not as a landed cost adjustment.";

    private const string NotPostedMessage = "Late charges are for posted invoices: edit the invoice's charges instead.";

    /// <summary>usp_LandedCostAdjustment_Search's page ceiling — far more adjustments than one invoice ever gets.</summary>
    private const int AdjustmentPageSize = 200;

    private readonly ILandedCostAdjustmentService _adjustments;
    private readonly ILandedCostAdjustmentRepository _adjustmentReader;
    private readonly IPurchaseDocumentRepository _invoices;
    private readonly IChargeTypeRepository _chargeTypes;
    private readonly ILogger<LateChargeService> _logger;

    public LateChargeService(
        ILandedCostAdjustmentService adjustments,
        ILandedCostAdjustmentRepository adjustmentReader,
        IPurchaseDocumentRepository invoices,
        IChargeTypeRepository chargeTypes,
        ILogger<LateChargeService> logger)
    {
        _adjustments = adjustments;
        _adjustmentReader = adjustmentReader;
        _invoices = invoices;
        _chargeTypes = chargeTypes;
        _logger = logger;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<LateChargesDto>> GetAsync(
        int invoiceId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.LandedCostsView))
        {
            return Forbidden<LateChargesDto>(Permissions.Purchase.LandedCostsView);
        }

        var invoice = await CheckInvoiceAsync(invoiceId, cancellationToken);
        if (invoice.IsFailure)
        {
            return Fail<LateChargesDto>(invoice);
        }

        return Result<LateChargesDto>.Success(ToLateCharges(await ReadAdjustmentsAsync(invoiceId, cancellationToken)));
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<LateChargesDto>> AddAsync(
        int invoiceId, SaveLateChargeRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.LandedCostsCreate))
        {
            return Forbidden<LateChargesDto>(Permissions.Purchase.LandedCostsCreate);
        }

        var invoice = await CheckInvoiceAsync(invoiceId, cancellationToken);
        if (invoice.IsFailure)
        {
            return Fail<LateChargesDto>(invoice);
        }

        var charge = await ToChargeAsync(request, includedInSupplierInvoice: false, cancellationToken);
        if (charge.IsFailure)
        {
            return Fail<LateChargesDto>(charge);
        }

        var draft = OpenDraft(await ReadAdjustmentsAsync(invoiceId, cancellationToken));
        var kept = draft?.Charges.OrderBy(c => c.LineNumber).ToList() ?? [];
        if (draft is not null && RefuseManualSplit(draft, kept) is { } refused)
        {
            return Fail<LateChargesDto>(refused);
        }

        var saved = await SaveDraftAsync(
            invoiceId, draft, request.ChargeDate!.Value, [.. kept.Select(Resend), charge.Value!],
            userId, permissions, cancellationToken);
        if (saved.IsFailure)
        {
            return Fail<LateChargesDto>(saved);
        }

        _logger.LogInformation(
            "Late charge added to adjustment {AdjustmentId} of invoice {InvoiceId} by user {UserId}", saved.Value, invoiceId, userId);
        return await ReadLateChargesAsync(invoiceId, cancellationToken);
    }

    public async Task<Result<LateChargesDto>> UpdateAsync(
        int invoiceId, int chargeId, SaveLateChargeRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.LandedCostsCreate))
        {
            return Forbidden<LateChargesDto>(Permissions.Purchase.LandedCostsCreate);
        }

        var found = await FindDraftChargeAsync(invoiceId, chargeId, cancellationToken);
        if (found.IsFailure)
        {
            return Fail<LateChargesDto>(found);
        }

        var (adjustment, existing) = found.Value;
        var charge = await ToChargeAsync(request, existing.IncludedInSupplierInvoice, cancellationToken);
        if (charge.IsFailure)
        {
            return Fail<LateChargesDto>(charge);
        }

        if (RefuseManualSplit(adjustment, adjustment.Charges.Where(c => c.Id != chargeId)) is { } refused)
        {
            return Fail<LateChargesDto>(refused);
        }

        var charges = adjustment.Charges
            .OrderBy(c => c.LineNumber)
            .Select(c => c.Id == chargeId ? charge.Value! : Resend(c))
            .ToList();

        var saved = await SaveDraftAsync(
            invoiceId, adjustment, request.ChargeDate!.Value, charges, userId, permissions, cancellationToken);
        if (saved.IsFailure)
        {
            return Fail<LateChargesDto>(saved);
        }

        _logger.LogInformation(
            "Late charge {ChargeId} of invoice {InvoiceId} changed by user {UserId}", chargeId, invoiceId, userId);
        return await ReadLateChargesAsync(invoiceId, cancellationToken);
    }

    public async Task<Result<LateChargesDto>> DeleteAsync(
        int invoiceId, int chargeId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.LandedCostsCreate))
        {
            return Forbidden<LateChargesDto>(Permissions.Purchase.LandedCostsCreate);
        }

        var found = await FindDraftChargeAsync(invoiceId, chargeId, cancellationToken);
        if (found.IsFailure)
        {
            return Fail<LateChargesDto>(found);
        }

        var (adjustment, _) = found.Value;
        var remaining = adjustment.Charges.Where(c => c.Id != chargeId).OrderBy(c => c.LineNumber).ToList();

        if (remaining.Count == 0)
        {
            // An adjustment with no charge cannot be saved (67000), and an empty draft is nothing to post.
            var deleted = await _adjustments.DeleteAsync(adjustment.Id, userId, permissions, cancellationToken);
            if (deleted.IsFailure)
            {
                return Fail<LateChargesDto>(deleted);
            }
        }
        else
        {
            if (RefuseManualSplit(adjustment, remaining) is { } refused)
            {
                return Fail<LateChargesDto>(refused);
            }

            var saved = await SaveDraftAsync(
                invoiceId, adjustment, DateOnly.FromDateTime(adjustment.DocumentDate), [.. remaining.Select(Resend)],
                userId, permissions, cancellationToken);
            if (saved.IsFailure)
            {
                return Fail<LateChargesDto>(saved);
            }
        }

        _logger.LogInformation(
            "Late charge {ChargeId} of invoice {InvoiceId} deleted by user {UserId}", chargeId, invoiceId, userId);
        return await ReadLateChargesAsync(invoiceId, cancellationToken);
    }

    public async Task<Result<LateChargesPostedDto>> PostAsync(
        int invoiceId, PostLateChargesRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.LandedCostsPost))
        {
            return Forbidden<LateChargesPostedDto>(Permissions.Purchase.LandedCostsPost);
        }

        var invoice = await CheckInvoiceAsync(invoiceId, cancellationToken);
        if (invoice.IsFailure)
        {
            return Fail<LateChargesPostedDto>(invoice);
        }

        var draft = OpenDraft(await ReadAdjustmentsAsync(invoiceId, cancellationToken));
        if (draft is null)
        {
            return Result<LateChargesPostedDto>.Failure(
                ErrorType.Conflict, "There are no draft late charges to post on this invoice.", "NO_DRAFT");
        }

        var posted = await _adjustments.PostAsync(draft.Id, request.RowVersion, userId, permissions, cancellationToken);
        if (posted.IsFailure)
        {
            return Fail<LateChargesPostedDto>(posted);
        }

        var adjustment = posted.Value!;
        return Result<LateChargesPostedDto>.Success(new LateChargesPostedDto
        {
            AdjustmentId = adjustment.Id,
            AdjustmentNumber = adjustment.DocumentNumber,
            Lines = adjustment.Lines.Select(l => new LateChargePostedLineDto
            {
                LineNo = l.LineNo,
                ItemCode = l.ItemCode,
                ItemName = l.ItemName,
                WarehouseCode = l.WarehouseCode,
                LandedCostBefore = l.LandedCostBefore,
                LandedCostAfter = l.LandedCostAfter,
                InventoryPortionBase = l.InventoryPortionBase,
                CogsPortionBase = l.CogsPortionBase,
            }).ToList(),
        });
    }

    public async Task<Result<LateChargesDto>> CancelAsync(
        int invoiceId, int adjustmentId, CancelLandedCostAdjustmentRequest request, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.LandedCostsCancel))
        {
            return Forbidden<LateChargesDto>(Permissions.Purchase.LandedCostsCancel);
        }

        var invoice = await CheckInvoiceAsync(invoiceId, cancellationToken);
        if (invoice.IsFailure)
        {
            return Fail<LateChargesDto>(invoice);
        }

        var adjustments = await ReadAdjustmentsAsync(invoiceId, cancellationToken);
        if (adjustments.All(a => a.Id != adjustmentId))
        {
            return Result<LateChargesDto>.Failure(ErrorType.NotFound, "Adjustment not found on this invoice.", "NOT_FOUND");
        }

        var cancelled = await _adjustments.CancelAsync(adjustmentId, request, userId, permissions, cancellationToken);
        if (cancelled.IsFailure)
        {
            return Fail<LateChargesDto>(cancelled);
        }

        return await ReadLateChargesAsync(invoiceId, cancellationToken);
    }

    /* ── the shared steps ─────────────────────────────────────────────────────────────────────── */

    /// <summary>A posted, local purchase invoice — or the reason it is not one.</summary>
    private async Task<Result> CheckInvoiceAsync(int invoiceId, CancellationToken cancellationToken)
    {
        var invoice = await _invoices.GetAsync(invoiceId, cancellationToken);
        if (invoice is null || invoice.DocumentTypeCode != PurchaseDocumentTypes.Invoice)
        {
            return Result.Failure(ErrorType.NotFound, "Purchase invoice not found.", "NOT_FOUND");
        }

        // Imported first: on a draft from containers the answer is "the containers", not "post it first".
        if (invoice.IsContainerBound)
        {
            return Result.Failure(ErrorType.Conflict, ImportedInvoiceMessage, "IMPORTED_INVOICE");
        }

        return invoice.Status == PurchaseDocumentStatus.Posted
            ? Result.Success()
            : Result.Failure(ErrorType.Conflict, NotPostedMessage, "INVOICE_NOT_POSTED");
    }

    /// <summary>Every adjustment of the invoice with its charges and split, the newest first.</summary>
    private async Task<IReadOnlyList<LandedCostAdjustmentDto>> ReadAdjustmentsAsync(int invoiceId, CancellationToken cancellationToken)
    {
        var (items, _) = await _adjustmentReader.SearchAsync(
            new LandedCostAdjustmentQuery { SourceInvoiceId = invoiceId, Page = 1, PageSize = AdjustmentPageSize },
            cancellationToken);

        var adjustments = new List<LandedCostAdjustmentDto>(items.Count);
        foreach (var item in items.OrderByDescending(a => a.Id))
        {
            if (await _adjustmentReader.GetAsync(item.Id, cancellationToken) is { } adjustment)
            {
                adjustments.Add(adjustment);
            }
        }

        return adjustments;
    }

    private async Task<Result<LateChargesDto>> ReadLateChargesAsync(int invoiceId, CancellationToken cancellationToken)
        => Result<LateChargesDto>.Success(ToLateCharges(await ReadAdjustmentsAsync(invoiceId, cancellationToken)));

    /// <summary>
    /// THE NEWEST DRAFT IS THE OPEN ONE. These endpoints never make a second, but the Landed Cost
    /// Adjustments page can; an older draft's charges are still listed, and still editable.
    /// </summary>
    private static LandedCostAdjustmentDto? OpenDraft(IReadOnlyList<LandedCostAdjustmentDto> adjustments)
        => adjustments.Where(a => a.Status == LandedCostAdjustmentStatus.Draft).MaxBy(a => a.Id);

    private async Task<Result<(LandedCostAdjustmentDto Adjustment, PurchaseChargeDto Charge)>> FindDraftChargeAsync(
        int invoiceId, int chargeId, CancellationToken cancellationToken)
    {
        var invoice = await CheckInvoiceAsync(invoiceId, cancellationToken);
        if (invoice.IsFailure)
        {
            return Fail<(LandedCostAdjustmentDto, PurchaseChargeDto)>(invoice);
        }

        foreach (var adjustment in await ReadAdjustmentsAsync(invoiceId, cancellationToken))
        {
            if (adjustment.Charges.FirstOrDefault(c => c.Id == chargeId) is not { } charge)
            {
                continue;
            }

            return adjustment.Status == LandedCostAdjustmentStatus.Draft
                ? Result<(LandedCostAdjustmentDto, PurchaseChargeDto)>.Success((adjustment, charge))
                : Result<(LandedCostAdjustmentDto, PurchaseChargeDto)>.Failure(
                    ErrorType.Conflict,
                    $"Only draft late charges can be changed: this one is {adjustment.Status.ToLowerInvariant()} with {adjustment.DocumentNumber}.",
                    "NOT_DRAFT");
        }

        return Result<(LandedCostAdjustmentDto, PurchaseChargeDto)>.Failure(
            ErrorType.NotFound, "Late charge not found on this invoice. Reload: a draft's charges are renumbered when it is saved.", "NOT_FOUND");
    }

    /// <summary>
    /// The draft with <paramref name="charges"/>, through the adjustment service; returns its id.
    /// A null <paramref name="draft"/> creates one, numbered now.
    /// </summary>
    private async Task<Result<int>> SaveDraftAsync(
        int invoiceId, LandedCostAdjustmentDto? draft, DateOnly date, IReadOnlyList<PurchaseChargeRequest> charges,
        int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken)
    {
        var numbered = charges.Select((c, index) => Numbered(c, index + 1)).ToList();
        var saved = await _adjustments.SaveDraftAsync(
            draft?.Id,
            new SaveLandedCostAdjustmentRequest
            {
                SourceInvoiceId = invoiceId,
                DocumentDate = date,
                Notes = draft?.Notes,
                Charges = numbered,
                RowVersion = draft is null ? null : Convert.ToBase64String(draft.RowVersion),
            },
            userId, permissions, cancellationToken);

        return saved.IsSuccess ? Result<int>.Success(saved.Value!.Id) : Fail<int>(saved);
    }

    /// <summary>
    /// A manual split cannot be sent back: the adjustment's read gives each charge's total, not its
    /// cells, and the writer refuses a manual charge without them. Such a draft (made on the Landed
    /// Cost Adjustments page) is edited there.
    /// </summary>
    private static Result? RefuseManualSplit(LandedCostAdjustmentDto adjustment, IEnumerable<PurchaseChargeDto> resent)
    {
        var manual = resent.FirstOrDefault(c =>
            c.AllocationMethod == ChargeAllocationMethods.Manual && c.IncludeInLandedCost && c.AmountBase > 0);

        return manual is null
            ? null
            : Result.Failure(
                ErrorType.Conflict,
                $"{adjustment.DocumentNumber} has a manually allocated charge ({manual.ChargeName}): change it on the Landed Cost Adjustments page.",
                "MANUAL_ALLOCATION");
    }

    /// <summary>
    /// The page's charge as the adjustment takes it. The method and the landed-cost flag are checked
    /// against the type here because the writer would not refuse them: an unknown method falls back to
    /// the type's, and the flag is always the type's.
    /// </summary>
    private async Task<Result<PurchaseChargeRequest>> ToChargeAsync(
        SaveLateChargeRequest request, bool includedInSupplierInvoice, CancellationToken cancellationToken)
    {
        if (request.ChargeDate is null)
        {
            return Result<PurchaseChargeRequest>.Failure(ErrorType.Validation, "Charge date is required.", "VALIDATION");
        }

        var type = await _chargeTypes.GetAsync(request.ChargeTypeId, cancellationToken);
        if (type is null)
        {
            return Result<PurchaseChargeRequest>.Failure(ErrorType.Validation, "Charge type not found.", "VALIDATION");
        }

        var method = request.AllocationMethod is null
            ? type.AllocationMethod
            : ChargeAllocationMethods.Normalize(request.AllocationMethod);
        if (method is null)
        {
            return Result<PurchaseChargeRequest>.Failure(
                ErrorType.Validation, $"Unknown allocation method '{request.AllocationMethod}'.", "VALIDATION");
        }

        if (method == ChargeAllocationMethods.Manual)
        {
            return Result<PurchaseChargeRequest>.Failure(
                ErrorType.Validation,
                "A late charge cannot be allocated manually: choose Value, Quantity, Weight or Volume.",
                "VALIDATION");
        }

        if (request.IncludeInLandedCost is { } included && included != type.IncludeInLandedCost)
        {
            return Result<PurchaseChargeRequest>.Failure(
                ErrorType.Validation,
                $"'Include in landed cost' comes from the charge type: {type.ChargeName} is {(type.IncludeInLandedCost ? "in" : "not in")} the landed cost.",
                "VALIDATION");
        }

        return Result<PurchaseChargeRequest>.Success(new PurchaseChargeRequest
        {
            ChargeTypeId = request.ChargeTypeId,
            Description = request.Description,
            ProviderPartyId = request.ProviderPartyId,
            Reference = request.Reference,
            CurrencyId = request.CurrencyId,
            RateType = request.RateType,
            ExchangeRate = request.ExchangeRate,
            Amount = request.Amount,
            AllocationMethod = method,
            IncludedInSupplierInvoice = includedInSupplierInvoice,
            Notes = request.Notes,
        });
    }

    /// <summary>A stored charge sent back unchanged — with its own rate, so a new draft date does not re-convert it.</summary>
    private static PurchaseChargeRequest Resend(PurchaseChargeDto charge) => new()
    {
        LineNumber = charge.LineNumber,
        ChargeTypeId = charge.ChargeTypeId,
        Description = charge.Description,
        ProviderPartyId = charge.ProviderPartyId,
        Reference = charge.Reference,
        CurrencyId = charge.CurrencyId,
        RateType = charge.RateType,
        ExchangeRate = charge.ExchangeRate,
        Amount = charge.Amount,
        AllocationMethod = charge.AllocationMethod,
        IncludedInSupplierInvoice = charge.IncludedInSupplierInvoice,
        Notes = charge.Notes,
    };

    private static PurchaseChargeRequest Numbered(PurchaseChargeRequest charge, int lineNumber) => new()
    {
        LineNumber = lineNumber,
        ChargeTypeId = charge.ChargeTypeId,
        Description = charge.Description,
        ProviderPartyId = charge.ProviderPartyId,
        Reference = charge.Reference,
        CurrencyId = charge.CurrencyId,
        RateType = charge.RateType,
        ExchangeRate = charge.ExchangeRate,
        Amount = charge.Amount,
        AllocationMethod = charge.AllocationMethod,
        IncludedInSupplierInvoice = charge.IncludedInSupplierInvoice,
        Notes = charge.Notes,
    };

    private static LateChargesDto ToLateCharges(IReadOnlyList<LandedCostAdjustmentDto> adjustments)
    {
        var draft = OpenDraft(adjustments);

        return new LateChargesDto
        {
            DraftAdjustment = draft is null
                ? null
                : new LateChargeDraftDto
                {
                    Id = draft.Id,
                    Number = draft.DocumentNumber,
                    Date = draft.DocumentDate,
                    RowVersion = draft.RowVersion,
                    TotalBase = draft.TotalChargesBase,
                },
            Charges = adjustments
                .SelectMany(a => a.Charges.OrderBy(c => c.LineNumber).Select(c => new LateChargeDto
                {
                    Id = c.Id,
                    AdjustmentId = a.Id,
                    AdjustmentNumber = a.DocumentNumber,
                    Status = a.Status,
                    PostedAtUtc = a.PostedAtUtc,
                    LineNumber = c.LineNumber,
                    ChargeTypeId = c.ChargeTypeId,
                    ChargeTypeCode = c.ChargeCode,
                    ChargeTypeName = c.ChargeName,
                    Description = c.Description,
                    ProviderPartyId = c.ProviderPartyId,
                    ProviderName = c.ProviderName,
                    Reference = c.Reference,
                    ChargeDate = a.DocumentDate,
                    CurrencyId = c.CurrencyId,
                    CurrencyCode = c.CurrencyCode,
                    RateType = c.RateType,
                    ExchangeRate = c.ExchangeRate,
                    Amount = c.Amount,
                    AmountBase = c.AmountBase,
                    AllocationMethod = c.AllocationMethod,
                    IncludeInLandedCost = c.IncludeInLandedCost,
                    Notes = c.Notes,
                    AllocatedBase = c.AllocatedBase,
                }))
                .ToList(),
        };
    }

    private static Result<T> Forbidden<T>(string permission)
        => Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", ForbiddenCode);

    /// <summary>A failure passed on as it came: the adjustment service's 67xxx classification is the answer.</summary>
    private static Result<T> Fail<T>(Result failed)
        => Result<T>.Failure(failed.ErrorType, failed.Error ?? "The request failed.", failed.Code ?? "VALIDATION", failed.Data);
}
