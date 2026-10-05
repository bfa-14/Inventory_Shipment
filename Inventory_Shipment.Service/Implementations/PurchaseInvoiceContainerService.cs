using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// A purchase invoice and its containers (script 43).
///
/// THE INVOICE DECIDES, THE ORDER CARRIES. Containers are always the order's — created by the order's own procedures,
/// with the order's checks — and the invoice only says which of its pieces are in which of them. Adding containers
/// from the invoice therefore creates them on the invoice's order and links them in the same transaction: a link the
/// invoice refuses takes the new containers with it.
///
/// Refusals keep the procedures' sentences: the invoice's 65xxx are classified as the purchase documents classify
/// them, the containers' 69xxx / 70xxx as the container services do.
///
/// THE RULES ARE THE DATABASE'S (script 51): whether an invoice may take containers - and why not - is decided by
/// purchase.usp_PurchaseInvoice_CheckContainers, which the order's procedures also run first. It is asked here before
/// anything is built, so a refusal names the invoice's rule (65030, or 65031 with the figures) and every answer carries
/// the state the page shows. Only the permissions (rule 9) are checked in this class.
/// </summary>
public sealed class PurchaseInvoiceContainerService : IPurchaseInvoiceContainerService
{
    private const string ForbiddenCode = "FORBIDDEN";
    private const string NotFoundMessage = "Purchase invoice not found.";

    private readonly IPurchaseInvoiceContainerRepository _links;
    private readonly IPurchaseDocumentRepository _invoices;
    private readonly IContainerService _containers;
    private readonly TimeProvider _clock;
    private readonly ILogger<PurchaseInvoiceContainerService> _logger;

    public PurchaseInvoiceContainerService(
        IPurchaseInvoiceContainerRepository links,
        IPurchaseDocumentRepository invoices,
        IContainerService containers,
        TimeProvider clock,
        ILogger<PurchaseInvoiceContainerService> logger)
    {
        _links = links;
        _invoices = invoices;
        _containers = containers;
        _clock = clock;
        _logger = logger;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<InvoiceContainerSummaryDto>> GetSummaryAsync(
        int invoiceId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.InvoicesView))
        {
            return Forbidden<InvoiceContainerSummaryDto>(Permissions.Purchase.InvoicesView);
        }

        var invoice = await ReadInvoiceAsync(invoiceId, cancellationToken);
        if (invoice.IsFailure)
        {
            return Fail<InvoiceContainerSummaryDto>(invoice);
        }

        var summary = await _links.GetSummaryAsync(invoiceId, cancellationToken);
        return Result<InvoiceContainerSummaryDto>.Success(await WithStateAsync(summary, invoiceId, userId, cancellationToken));
    }

    public async Task<Result<IReadOnlyList<InvoiceLinkCandidateDto>>> GetCandidatesAsync(
        int invoiceId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.InvoicesView))
        {
            return Forbidden<IReadOnlyList<InvoiceLinkCandidateDto>>(Permissions.Purchase.InvoicesView);
        }

        var invoice = await ReadInvoiceAsync(invoiceId, cancellationToken);
        if (invoice.IsFailure)
        {
            return Fail<IReadOnlyList<InvoiceLinkCandidateDto>>(invoice);
        }

        return Result<IReadOnlyList<InvoiceLinkCandidateDto>>.Success(await _links.GetCandidatesAsync(invoiceId, cancellationToken));
    }

    /* ── link / unlink ────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<InvoiceContainerSummaryDto>> LinkAsync(
        int invoiceId, LinkInvoiceContainersRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.InvoicesCreate))
        {
            return Forbidden<InvoiceContainerSummaryDto>(Permissions.Purchase.InvoicesCreate);
        }

        if (request.Links.Count == 0)
        {
            return Result<InvoiceContainerSummaryDto>.Failure(ErrorType.Validation, "Choose at least one container line to link.", "VALIDATION");
        }

        // Said here with the line's id: the table type would refuse it as a key violation nobody has heard of.
        var twice = request.Links.GroupBy(l => l.ContainerLineId).FirstOrDefault(g => g.Count() > 1);
        if (twice is not null)
        {
            return Result<InvoiceContainerSummaryDto>.Failure(
                ErrorType.Validation, $"Container line {twice.Key} appears more than once.", "VALIDATION");
        }

        var invoice = await ReadInvoiceAsync(invoiceId, cancellationToken);
        if (invoice.IsFailure)
        {
            return Fail<InvoiceContainerSummaryDto>(invoice);
        }

        try
        {
            var summary = await _links.LinkAsync(invoiceId, request.Links, ToRowVersion(request.RowVersion), userId, cancellationToken);
            _logger.LogInformation("Purchase invoice {InvoiceId} linked to {Count} container line(s) by user {UserId}",
                invoiceId, request.Links.Count, userId);
            return Result<InvoiceContainerSummaryDto>.Success(await WithStateAsync(summary, invoiceId, userId, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Fail<InvoiceContainerSummaryDto>(ex);
        }
    }

    public async Task<Result<InvoiceContainerSummaryDto>> UnlinkAsync(
        int invoiceId, int containerId, string? rowVersion, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.InvoicesCreate))
        {
            return Forbidden<InvoiceContainerSummaryDto>(Permissions.Purchase.InvoicesCreate);
        }

        var invoice = await ReadInvoiceAsync(invoiceId, cancellationToken);
        if (invoice.IsFailure)
        {
            return Fail<InvoiceContainerSummaryDto>(invoice);
        }

        try
        {
            var summary = await _links.UnlinkAsync(invoiceId, containerId, ToRowVersion(rowVersion), userId, cancellationToken);
            _logger.LogInformation("Purchase invoice {InvoiceId} unlinked from container {ContainerId} by user {UserId}",
                invoiceId, containerId, userId);
            return Result<InvoiceContainerSummaryDto>.Success(await WithStateAsync(summary, invoiceId, userId, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Fail<InvoiceContainerSummaryDto>(ex);
        }
    }

    /* ── containers added from the invoice ────────────────────────────────────────────────────── */

    public async Task<Result<InvoiceContainersCreatedDto>> AddContainerAsync(
        int invoiceId, AddInvoiceContainerRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (CheckAddRights(permissions, request.AllowOverCapacity, confirm: false, request.ShippingMethod) is { } refused)
        {
            return Fail<InvoiceContainersCreatedDto>(refused);
        }

        var read = await ReadInvoiceAsync(invoiceId, cancellationToken);
        if (read.IsFailure)
        {
            return Fail<InvoiceContainersCreatedDto>(read);
        }

        if (await CheckRulesAsync(invoiceId, "Add", request.QuantityBase, cancellationToken) is { } broken)
        {
            return Fail<InvoiceContainersCreatedDto>(broken);
        }

        var invoice = read.Value!;
        var lines = ContainerLinesFor(invoice, request.ItemId, request.QuantityBase, request.OilIncluded, request.OilQtyPerUnit);
        if (lines.IsFailure)
        {
            return Fail<InvoiceContainersCreatedDto>(lines);
        }

        var container = new SaveContainerRequest
        {
            PurchaseOrderId = invoice.SourceDocumentId,
            ContainerNo = request.ContainerNo,
            ContainerTypeId = request.ContainerTypeId,
            SealNo = request.SealNo,
            CustomsSealNo = request.CustomsSealNo,
            Description = request.Description,
            OrderDate = request.OrderDate ?? DateOnly.FromDateTime(_clock.GetUtcNow().UtcDateTime),
            ShippingMethod = request.ShippingMethod is null ? null : ShippingMethods.Normalize(request.ShippingMethod),
            CountryOfOrigin = request.CountryOfOrigin,
            ForwarderId = request.ForwarderId,
            TransporterId = request.TransporterId,
            ShippingLine = request.ShippingLine,
            VesselName = request.VesselName,
            VoyageNo = request.VoyageNo,
            BookingNo = request.BookingNo,
            PortOfLoadingId = request.PortOfLoadingId,
            PortOfDestinationId = request.PortOfDestinationId,
            FinalDestinationId = request.FinalDestinationId,
            DispatchDate = request.DispatchDate,
            Eta = request.Eta,
            FreeDays = request.FreeDays,
            BranchId = request.BranchId ?? invoice.BranchId,
            WarehouseId = request.WarehouseId ?? invoice.WarehouseId,
            Notes = request.Notes,
            Lines = lines.Value!,
            AllowOverCapacity = request.AllowOverCapacity,
        };

        try
        {
            var created = await _links.AddContainerAsync(invoiceId, container, ToRowVersion(request.RowVersion), userId, cancellationToken);
            _logger.LogInformation("Container {ContainerId} added from purchase invoice {InvoiceId} by user {UserId}{Override}",
                created.Created.FirstOrDefault()?.ContainerId, invoiceId, userId,
                request.AllowOverCapacity ? " (over capacity confirmed)" : string.Empty);
            return Result<InvoiceContainersCreatedDto>.Success(await WithStateAsync(created, invoiceId, userId, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Fail<InvoiceContainersCreatedDto>(ex, permissions);
        }
    }

    public async Task<Result<AutoPlanDto>> AutoPlanAsync(
        int invoiceId, InvoiceAutoPlanRequest request, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        // The proposal is the first step of adding containers: the same rights (rule 9).
        if (CheckAddRights(permissions, allowOverCapacity: false, confirm: false, shippingMethod: null) is { } refused)
        {
            return Fail<AutoPlanDto>(refused);
        }

        var read = await ReadInvoiceAsync(invoiceId, cancellationToken);
        if (read.IsFailure)
        {
            return Fail<AutoPlanDto>(read);
        }

        if (await CheckRulesAsync(invoiceId, "Plan", null, cancellationToken) is { } broken)
        {
            return Fail<AutoPlanDto>(broken);
        }

        // The order's own proposal (its checks, containers.create included), for this invoice's pieces only.
        return await _containers.AutoPlanAsync(new AutoPlanRequest
        {
            PurchaseOrderId = read.Value!.SourceDocumentId!.Value,
            ContainerTypeId = request.ContainerTypeId,
            MixRemainders = request.MixRemainders,
            Capacities = request.Capacities,
            ForInvoiceId = invoiceId,
        }, permissions, cancellationToken);
    }

    public async Task<Result<InvoiceContainersCreatedDto>> CreateFromPlanAsync(
        int invoiceId, InvoiceContainersFromPlanRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (CheckAddRights(permissions, request.AllowOverCapacity, request.Confirm, request.ShippingMethod) is { } refused)
        {
            return Fail<InvoiceContainersCreatedDto>(refused);
        }

        if (ContainerService.CheckPlan(request.Containers) is { } invalid)
        {
            return Result<InvoiceContainersCreatedDto>.Failure(ErrorType.Validation, invalid, "VALIDATION");
        }

        var read = await ReadInvoiceAsync(invoiceId, cancellationToken);
        if (read.IsFailure)
        {
            return Fail<InvoiceContainersCreatedDto>(read);
        }

        var pieces = request.Containers.Sum(c => c.Lines.Sum(l => l.QuantityBase));
        if (await CheckRulesAsync(invoiceId, "Add", pieces, cancellationToken) is { } broken)
        {
            return Fail<InvoiceContainersCreatedDto>(broken);
        }

        var plan = new CreateContainersFromPlanRequest
        {
            PurchaseOrderId = read.Value!.SourceDocumentId!.Value,
            ContainerTypeId = request.ContainerTypeId,
            OrderDate = request.OrderDate,
            BranchId = request.BranchId,
            WarehouseId = request.WarehouseId,
            ShippingMethod = request.ShippingMethod,
            CountryOfOrigin = request.CountryOfOrigin,
            ForwarderId = request.ForwarderId,
            ShippingLine = request.ShippingLine,
            PortOfLoadingId = request.PortOfLoadingId,
            PortOfDestinationId = request.PortOfDestinationId,
            FinalDestinationId = request.FinalDestinationId,
            Eta = request.Eta,
            FreeDays = request.FreeDays,
            Containers = request.Containers,
            Capacities = request.Capacities,
            AllowOverCapacity = request.AllowOverCapacity,
            Confirm = request.Confirm,
        };

        try
        {
            var created = await _links.CreateFromPlanAsync(invoiceId, plan, ToRowVersion(request.RowVersion), userId, cancellationToken);
            _logger.LogInformation("{Count} container(s) created from the plan of purchase invoice {InvoiceId} by user {UserId}",
                created.Created.Count, invoiceId, userId);
            return Result<InvoiceContainersCreatedDto>.Success(await WithStateAsync(created, invoiceId, userId, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Fail<InvoiceContainersCreatedDto>(ex, permissions);
        }
    }

    /* ── the shared steps ─────────────────────────────────────────────────────────────────────── */

    /// <summary>The rights of adding containers: the invoice's edit permission, then the container service's own rules.</summary>
    private static Result? CheckAddRights(IReadOnlySet<string> permissions, bool allowOverCapacity, bool confirm, string? shippingMethod)
    {
        foreach (var permission in new[] { Permissions.Purchase.InvoicesCreate, Permissions.Containers.Create })
        {
            if (!permissions.Contains(permission))
            {
                return Result.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", ForbiddenCode);
            }
        }

        if (allowOverCapacity && !permissions.Contains(Permissions.Containers.OverCapacity))
        {
            return Result.Failure(ErrorType.Forbidden,
                $"Loading a container above its capacity needs the {Permissions.Containers.OverCapacity} permission.", ForbiddenCode);
        }

        if (confirm && !permissions.Contains(Permissions.Containers.Confirm))
        {
            return Result.Failure(ErrorType.Forbidden,
                $"Confirming the new containers needs the {Permissions.Containers.Confirm} permission.", ForbiddenCode);
        }

        return shippingMethod is not null && ShippingMethods.Normalize(shippingMethod) is null
            ? Result.Failure(ErrorType.Validation, "Shipping method must be Sea, Air or Road.", "VALIDATION")
            : null;
    }

    private async Task<Result<PurchaseDocumentDto>> ReadInvoiceAsync(int invoiceId, CancellationToken cancellationToken)
    {
        var invoice = await _invoices.GetAsync(invoiceId, cancellationToken);
        return invoice is null || invoice.DocumentTypeCode != PurchaseDocumentTypes.Invoice
            ? Result<PurchaseDocumentDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<PurchaseDocumentDto>.Success(invoice);
    }

    /// <summary>
    /// The invoice's rules (script 51) for an action - Add (1-8, with the pieces asked), Plan (1-7) - asked of the
    /// database before anything is built; null when they hold. Its refusal is the purchase documents' 65030 / 65031.
    /// </summary>
    private async Task<Result?> CheckRulesAsync(int invoiceId, string action, int? quantityBase, CancellationToken cancellationToken)
    {
        try
        {
            await _links.CheckAsync(invoiceId, action, quantityBase, cancellationToken);
            return null;
        }
        catch (BusinessRuleException ex)
        {
            var failure = PurchaseDocumentService.Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }
    }

    /// <summary>The summary with the invoice's state as it is now, for the caller (rule 9 included).</summary>
    private async Task<InvoiceContainerSummaryDto> WithStateAsync(
        InvoiceContainerSummaryDto summary, int invoiceId, int userId, CancellationToken cancellationToken)
        => new()
        {
            Items = summary.Items,
            Containers = summary.Containers,
            State = await _links.GetStateAsync(invoiceId, userId, cancellationToken),
        };

    private async Task<InvoiceContainersCreatedDto> WithStateAsync(
        InvoiceContainersCreatedDto created, int invoiceId, int userId, CancellationToken cancellationToken)
        => new() { Created = created.Created, Summary = await WithStateAsync(created.Summary, invoiceId, userId, cancellationToken) };

    /// <summary>
    /// The new container's lines: the pieces asked for, taken from the invoice's ORDER LINES of one item in the
    /// invoice's order — a container line comes from one order line, and the invoice line it is linked to must come
    /// from the same one.
    /// </summary>
    private static Result<IReadOnlyList<SaveContainerLineRequest>> ContainerLinesFor(
        PurchaseDocumentDto invoice, int? itemId, int quantityBase, bool oilIncluded, decimal? oilQtyPerUnit)
    {
        var outside = invoice.Lines.Where(l => l.ContainerLineId is null && l.SourceLineId is not null).ToList();
        var items = outside.Select(l => l.ItemId).Distinct().ToList();

        if (items.Count == 0)
        {
            return Result<IReadOnlyList<SaveContainerLineRequest>>.Failure(
                ErrorType.Conflict, "Every piece of this invoice is already in a container.", "NOTHING_TO_LINK");
        }

        if (itemId is null && items.Count > 1)
        {
            return Result<IReadOnlyList<SaveContainerLineRequest>>.Failure(
                ErrorType.Validation, "This invoice has several items outside containers: choose the item of the container (itemId).", "VALIDATION");
        }

        var item = itemId ?? items[0];
        var ofItem = outside.Where(l => l.ItemId == item).ToList();
        if (ofItem.Count == 0)
        {
            return Result<IReadOnlyList<SaveContainerLineRequest>>.Failure(
                ErrorType.Validation, "This invoice has no pieces of that item outside containers.", "VALIDATION");
        }

        var available = (int)ofItem.Sum(l => l.QuantityBase);
        if (quantityBase > available)
        {
            return Result<IReadOnlyList<SaveContainerLineRequest>>.Failure(
                ErrorType.Validation,
                $"Only {available} pieces of {ofItem[0].ItemCode} are outside containers on this invoice.", "VALIDATION");
        }

        var lines = new List<SaveContainerLineRequest>();
        var left = quantityBase;
        foreach (var orderLine in ofItem.GroupBy(l => l.SourceLineId!.Value).OrderBy(g => g.Min(l => l.LineNo)))
        {
            if (left == 0)
            {
                break;
            }

            var take = Math.Min(left, (int)orderLine.Sum(l => l.QuantityBase));
            lines.Add(new SaveContainerLineRequest
            {
                LineNumber = lines.Count + 1,
                PoLineId = orderLine.Key,
                QuantityBase = take,
                OilIncluded = oilIncluded,
                OilQtyPerUnit = oilIncluded ? oilQtyPerUnit : null,
            });
            left -= take;
        }

        return Result<IReadOnlyList<SaveContainerLineRequest>>.Success(lines);
    }

    private static Result<T> Forbidden<T>(string permission)
        => Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", ForbiddenCode);

    private static Result<T> Fail<T>(Result failed)
        => Result<T>.Failure(failed.ErrorType, failed.Error ?? "The request failed.", failed.Code ?? "VALIDATION", failed.Data);

    /// <summary>
    /// A container procedure's refusal as the container services say it (over capacity with data.canOverride, as a
    /// single save does), an invoice procedure's as the purchase documents do.
    /// </summary>
    private static Result<T> Fail<T>(BusinessRuleException exception, IReadOnlySet<string>? permissions = null)
    {
        if (exception.Number is >= 69000 and < 71000)
        {
            var logistics = LogisticsRuleFailures.Describe(exception);
            return logistics.Code == "OVER_CAPACITY"
                ? Result<T>.Failure(logistics.Type, logistics.Message, logistics.Code,
                    new { canOverride = permissions?.Contains(Permissions.Containers.OverCapacity) == true })
                : Result<T>.Failure(logistics.Type, logistics.Message, logistics.Code);
        }

        var purchase = PurchaseDocumentService.Describe(exception);
        return Result<T>.Failure(purchase.Type, purchase.Message, purchase.Code);
    }

    private static byte[]? ToRowVersion(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return Convert.TryFromBase64String(value, new byte[8], out var written) && written == 8
            ? Convert.FromBase64String(value)
            : null;
    }
}
