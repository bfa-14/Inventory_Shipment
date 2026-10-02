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
/// </summary>
public sealed class PurchaseInvoiceContainerService : IPurchaseInvoiceContainerService
{
    private const string ForbiddenCode = "FORBIDDEN";
    private const string NotFoundMessage = "Purchase invoice not found.";

    /// <summary>The words of usp_PurchaseInvoice_LinkContainers's 65028, said before the order's procedures run.</summary>
    private const string NotFromOrderMessage = "Only a purchase invoice created from a purchase order can be linked to containers.";

    private const string ReceivedOnPostingMessage = "This invoice was received when it was posted: it cannot be linked to containers.";

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
        int invoiceId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
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

        return Result<InvoiceContainerSummaryDto>.Success(await _links.GetSummaryAsync(invoiceId, cancellationToken));
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
            return Result<InvoiceContainerSummaryDto>.Success(summary);
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
            return Result<InvoiceContainerSummaryDto>.Success(summary);
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

        var read = await ReadTakingContainersAsync(invoiceId, cancellationToken);
        if (read.IsFailure)
        {
            return Fail<InvoiceContainersCreatedDto>(read);
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
            MaxUnits = request.MaxUnits,
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
            return Result<InvoiceContainersCreatedDto>.Success(created);
        }
        catch (BusinessRuleException ex)
        {
            return Fail<InvoiceContainersCreatedDto>(ex, permissions);
        }
    }

    public async Task<Result<AutoPlanDto>> AutoPlanAsync(
        int invoiceId, InvoiceAutoPlanRequest request, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.InvoicesCreate))
        {
            return Forbidden<AutoPlanDto>(Permissions.Purchase.InvoicesCreate);
        }

        var read = await ReadTakingContainersAsync(invoiceId, cancellationToken);
        if (read.IsFailure)
        {
            return Fail<AutoPlanDto>(read);
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

        if ((ContainerService.CheckPlan(request.Containers) ?? ContainerService.CheckCapacities(request.Capacities)) is { } invalid)
        {
            return Result<InvoiceContainersCreatedDto>.Failure(ErrorType.Validation, invalid, "VALIDATION");
        }

        var read = await ReadTakingContainersAsync(invoiceId, cancellationToken);
        if (read.IsFailure)
        {
            return Fail<InvoiceContainersCreatedDto>(read);
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
            return Result<InvoiceContainersCreatedDto>.Success(created);
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
    /// An invoice the ORDER's procedures may create containers for: of an order, a draft or a posted invoice shipped in
    /// containers. Checked before them, so a refusal names the invoice rather than the order.
    /// </summary>
    private async Task<Result<PurchaseDocumentDto>> ReadTakingContainersAsync(int invoiceId, CancellationToken cancellationToken)
    {
        var read = await ReadInvoiceAsync(invoiceId, cancellationToken);
        if (read.IsFailure)
        {
            return read;
        }

        var invoice = read.Value!;
        if (invoice.SourceDocumentId is null)
        {
            return Result<PurchaseDocumentDto>.Failure(ErrorType.Conflict, NotFromOrderMessage, "NOT_LINKABLE");
        }

        if (invoice.Status is not (PurchaseDocumentStatus.Draft or PurchaseDocumentStatus.Posted))
        {
            return Result<PurchaseDocumentDto>.Failure(
                ErrorType.Conflict, "A cancelled invoice cannot be linked to containers.", "INVALID_STATUS");
        }

        return invoice.Status == PurchaseDocumentStatus.Posted && !invoice.ShippedInContainers
            ? Result<PurchaseDocumentDto>.Failure(ErrorType.Conflict, ReceivedOnPostingMessage, "NOT_LINKABLE")
            : read;
    }

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
