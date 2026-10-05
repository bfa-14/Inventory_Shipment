using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using static Inventory_Shipment.Service.Implementations.LogisticsRuleFailures;

namespace Inventory_Shipment.Service.Implementations;

public sealed class ContainerService : IContainerService
{
    private const string NotFoundMessage = "Container not found.";

    /// <summary>usp_Container_CreateBatch's own limit, said before the call.</summary>
    private const int MaxContainersPerPlan = 200;

    private readonly IContainerRepository _containers;
    private readonly ILogger<ContainerService> _logger;

    public ContainerService(IContainerRepository containers, ILogger<ContainerService> logger)
    {
        _containers = containers;
        _logger = logger;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<PagedResult<ContainerListDto>>> SearchAsync(
        ContainerQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.View))
        {
            return Forbidden<PagedResult<ContainerListDto>>(Permissions.Containers.View);
        }

        if (!string.IsNullOrWhiteSpace(query.Status) && ContainerStatus.ToCode(query.Status) is null)
        {
            return Result<PagedResult<ContainerListDto>>.Failure(
                ErrorType.Validation,
                "status must be 1-8 or Draft, Confirmed, InTransit, AtPort, Cleared, Offloaded, Closed, Cancelled.", "VALIDATION");
        }

        var (items, totalCount) = await _containers.SearchAsync(query, cancellationToken);

        return Result<PagedResult<ContainerListDto>>.Success(new PagedResult<ContainerListDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<ContainerDto>> GetAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.View))
        {
            return Forbidden<ContainerDto>(Permissions.Containers.View);
        }

        return await ReadAsync(id, cancellationToken);
    }

    public async Task<Result<IReadOnlyList<AvailablePoLineDto>>> GetAvailablePoLinesAsync(
        AvailablePoLineQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.Create))
        {
            return Forbidden<IReadOnlyList<AvailablePoLineDto>>(Permissions.Containers.Create);
        }

        return Result<IReadOnlyList<AvailablePoLineDto>>.Success(
            await _containers.GetAvailablePoLinesAsync(query, cancellationToken));
    }

    public async Task<Result<IReadOnlyList<InvoiceCandidateDto>>> GetInvoiceCandidatesAsync(
        InvoiceCandidateQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.View))
        {
            return Forbidden<IReadOnlyList<InvoiceCandidateDto>>(Permissions.Containers.View);
        }

        // Said here rather than by the procedure's 69000: without either filter it would be every
        // open container line of the company, which no page asks for.
        if (query.PurchaseOrderId is null && query.ContainerId is null)
        {
            return Result<IReadOnlyList<InvoiceCandidateDto>>.Failure(
                ErrorType.Validation, "Give a purchaseOrderId or a containerId.", "VALIDATION");
        }

        try
        {
            return Result<IReadOnlyList<InvoiceCandidateDto>>.Success(
                await _containers.GetInvoiceCandidatesAsync(query, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<InvoiceCandidateDto>>(ex);
        }
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// A NEW CONTAINER NEEDS ITS ORDER: said here so the page hears it as a 400 on the field rather
    /// than the procedure's sentence; on an update the order is the container's and is not sent.
    ///
    /// OVER CAPACITY IS A WARNING WITH AN OVERRIDE, NEVER A BLOCK — but the override is a right. A
    /// save without allowOverCapacity that goes over comes back 409 OVER_CAPACITY with the figures in
    /// the message and data.canOverride telling the page whether to offer the confirmation; a save
    /// WITH it from a caller who lacks containers.overcapacity is refused here, before the procedure.
    /// </summary>
    public async Task<Result<ContainerDto>> SaveAsync(
        int? id, SaveContainerRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.Create))
        {
            return Forbidden<ContainerDto>(Permissions.Containers.Create);
        }

        var canOverride = permissions.Contains(Permissions.Containers.OverCapacity);
        if (request.AllowOverCapacity && !canOverride)
        {
            return Result<ContainerDto>.Failure(
                ErrorType.Forbidden,
                $"Loading a container above its capacity needs the {Permissions.Containers.OverCapacity} permission.",
                "FORBIDDEN");
        }

        if (request.ShippingMethod is not null && ShippingMethods.Normalize(request.ShippingMethod) is null)
        {
            return Result<ContainerDto>.Failure(ErrorType.Validation, "Shipping method must be Sea, Air or Road.", "VALIDATION");
        }

        if (id is null && request.PurchaseOrderId is null)
        {
            return Result<ContainerDto>.Failure(
                ErrorType.Validation, "purchaseOrderId is required: a container is created from a purchase order.", "VALIDATION");
        }

        // Said here with the order line; the table type would refuse it too, as a constraint
        // violation nobody on the page has heard of.
        var twice = request.Lines.GroupBy(l => l.PoLineId).FirstOrDefault(g => g.Count() > 1);
        if (twice is not null)
        {
            return Result<ContainerDto>.Failure(
                ErrorType.Validation, $"Order line {twice.Key} appears more than once in the container.", "VALIDATION");
        }

        int savedId;
        try
        {
            savedId = await _containers.SaveAsync(request, id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return failure.Code == "OVER_CAPACITY"
                ? Result<ContainerDto>.Failure(failure.Type, failure.Message, failure.Code, new { canOverride })
                : Result<ContainerDto>.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Container {ContainerId} saved by user {UserId}{Override}",
            savedId, userId, request.AllowOverCapacity ? " (over capacity confirmed)" : string.Empty);

        return await ReadAsync(savedId, cancellationToken);
    }

    public Task<Result<ContainerDto>> ConfirmAsync(
        int id, ContainerActionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => ChangeAsync(id, Permissions.Containers.Confirm, permissions, userId, "confirmed", cancellationToken,
            () => _containers.ConfirmAsync(id, ToRowVersion(request.RowVersion), userId, cancellationToken));

    public Task<Result<ContainerDto>> OffloadAsync(
        int id, OffloadRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        // Said here with the line id; the table type's primary key would refuse the batch too, but as
        // a constraint violation nobody on the page has heard of — and a 500 rather than a 400.
        var duplicate = request.Lines.GroupBy(l => l.LineId).FirstOrDefault(g => g.Count() > 1);
        if (duplicate is not null)
        {
            return Task.FromResult(Result<ContainerDto>.Failure(
                ErrorType.Validation, $"Line {duplicate.Key} appears more than once.", "VALIDATION"));
        }

        return ChangeAsync(id, Permissions.Containers.Offload, permissions, userId, "offloaded", cancellationToken,
            () => _containers.OffloadAsync(id, request, ToRowVersion(request.RowVersion), userId, cancellationToken));
    }

    /// <summary>UNDOING THE OFFLOAD IS A CANCELLATION: the movements are reversed and the costs replayed, so it is the cancel right.</summary>
    public Task<Result<ContainerDto>> CancelOffloadAsync(
        int id, CancelRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => ChangeAsync(id, Permissions.Containers.Cancel, permissions, userId, "offload reversed", cancellationToken,
            () => _containers.CancelOffloadAsync(id, request.Reason, ToRowVersion(request.RowVersion), userId, cancellationToken));

    public Task<Result<ContainerDto>> CloseAsync(
        int id, ContainerActionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => ChangeAsync(id, Permissions.Containers.Close, permissions, userId, "closed", cancellationToken,
            () => _containers.CloseAsync(id, ToRowVersion(request.RowVersion), userId, cancellationToken));

    /// <summary>REOPENING UNDOES A CLOSE, so it is the close right — a late charge is the usual reason.</summary>
    public Task<Result<ContainerDto>> ReopenAsync(
        int id, ContainerActionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => ChangeAsync(id, Permissions.Containers.Close, permissions, userId, "reopened", cancellationToken,
            () => _containers.ReopenAsync(id, ToRowVersion(request.RowVersion), userId, cancellationToken));

    public Task<Result<ContainerDto>> CancelAsync(
        int id, CancelRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => ChangeAsync(id, Permissions.Containers.Cancel, permissions, userId, "cancelled", cancellationToken,
            () => _containers.CancelAsync(id, request.Reason, ToRowVersion(request.RowVersion), userId, cancellationToken));

    public async Task<Result> DeleteAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.Delete))
        {
            return Forbidden<ContainerDto>(Permissions.Containers.Delete);
        }

        try
        {
            await _containers.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        _logger.LogInformation("Container {ContainerId} deleted by user {UserId}", id, userId);
        return Result.Success();
    }

    /* ── tracking and attachments ─────────────────────────────────────────────────────────────── */

    public async Task<Result<TrackingDto>> GetTrackingAsync(
        TrackingQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.View))
        {
            return Forbidden<TrackingDto>(Permissions.Containers.View);
        }

        return Result<TrackingDto>.Success(await _containers.GetTrackingAsync(query, cancellationToken));
    }

    public async Task<Result<IReadOnlyList<ContainerAttachmentCreatedDto>>> AddAttachmentAsync(
        ContainerAttachmentUpload upload, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.AttachmentsManage))
        {
            return Forbidden<IReadOnlyList<ContainerAttachmentCreatedDto>>(Permissions.Containers.AttachmentsManage);
        }

        // A charge alone is enough (the procedure takes its container); otherwise at least one container.
        if (upload.ContainerIds.Count == 0 && upload.ChargeId is null)
        {
            return Result<IReadOnlyList<ContainerAttachmentCreatedDto>>.Failure(
                ErrorType.Validation, "Select at least one container.", "VALIDATION");
        }

        IReadOnlyList<ContainerAttachmentCreatedDto> created;
        try
        {
            created = await _containers.AddAttachmentAsync(upload, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<ContainerAttachmentCreatedDto>>(ex);
        }

        _logger.LogInformation("Attachment {FileName} added to {Count} container(s) by user {UserId}",
            upload.FileName, created.Count, userId);
        return Result<IReadOnlyList<ContainerAttachmentCreatedDto>>.Success(created);
    }

    public async Task<Result<ContainerAttachmentFile>> GetAttachmentFileAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.View))
        {
            return Forbidden<ContainerAttachmentFile>(Permissions.Containers.View);
        }

        var file = await _containers.GetAttachmentFileAsync(id, cancellationToken);
        return file is null
            ? Result<ContainerAttachmentFile>.Failure(ErrorType.NotFound, "Attachment not found.", "NOT_FOUND")
            : Result<ContainerAttachmentFile>.Success(file);
    }

    public async Task<Result> DeleteAttachmentAsync(
        int id, bool allShared, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.AttachmentsManage))
        {
            return Forbidden<ContainerDto>(Permissions.Containers.AttachmentsManage);
        }

        try
        {
            await _containers.DeleteAttachmentAsync(id, allShared, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        _logger.LogInformation("Attachment {AttachmentId} deleted{Shared} by user {UserId}",
            id, allShared ? " from every container" : string.Empty, userId);
        return Result.Success();
    }

    public async Task<Result<IReadOnlyList<ContainerAttachmentDto>>> ListAttachmentsAsync(
        int? containerId, int? movementId, int? attachmentTypeId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.View))
        {
            return Forbidden<IReadOnlyList<ContainerAttachmentDto>>(Permissions.Containers.View);
        }

        if (containerId is null && movementId is null)
        {
            return Result<IReadOnlyList<ContainerAttachmentDto>>.Failure(
                ErrorType.Validation, "Choose a container or a movement.", "VALIDATION");
        }

        return Result<IReadOnlyList<ContainerAttachmentDto>>.Success(
            await _containers.ListAttachmentsAsync(containerId, movementId, attachmentTypeId, cancellationToken: cancellationToken));
    }

    public async Task<Result<ContainerAttachmentDto>> UpdateAttachmentAsync(
        int id, DocumentFileFields fields, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.AttachmentsManage))
        {
            return Forbidden<ContainerAttachmentDto>(Permissions.Containers.AttachmentsManage);
        }

        try
        {
            var attachment = await _containers.UpdateAttachmentAsync(id, fields, userId, cancellationToken);
            return attachment is null
                ? Result<ContainerAttachmentDto>.Failure(ErrorType.NotFound, "Attachment not found.", "NOT_FOUND")
                : Result<ContainerAttachmentDto>.Success(attachment);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ContainerAttachmentDto>(ex);
        }
    }

    /* ── many containers per order (script 28) ────────────────────────────────────────────────── */

    public async Task<Result<AutoPlanDto>> AutoPlanAsync(
        AutoPlanRequest request, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.Create))
        {
            return Forbidden<AutoPlanDto>(Permissions.Containers.Create);
        }

        // The typed pieces per container (request.Capacities) are ignored since script 50: the Container units only.
        try
        {
            return Result<AutoPlanDto>.Success(await _containers.PlanFromOrderAsync(request, cancellationToken));
        }
        catch (BusinessRuleException ex) when (ex.Number == SqlErrors.ContainerValidation
                                                && ex.Message.EndsWith(MissingContainerUnit, StringComparison.Ordinal))
        {
            return Result<AutoPlanDto>.Success(await BlockedPlanAsync(request.PurchaseOrderId, ex.Message, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<AutoPlanDto>(ex);
        }
    }

    /// <summary>The end of the procedure's 69000 for an item without a Container unit (script 50).</summary>
    private const string MissingContainerUnit = "set its Container unit in Item Definition first.";

    /// <summary>
    /// NO PLAN WITHOUT THE PIECES PER CONTAINER OF EVERY ITEM, but the dialog still needs the order lines to say which
    /// item to fix: each with its pieces per container ("Item Definition"), or the procedure's sentence and no number.
    /// </summary>
    private async Task<AutoPlanDto> BlockedPlanAsync(int purchaseOrderId, string message, CancellationToken cancellationToken)
    {
        var lines = await _containers.GetAvailablePoLinesAsync(new AvailablePoLineQuery { PurchaseOrderId = purchaseOrderId }, cancellationToken);
        return new AutoPlanDto
        {
            Message = message,
            OrderLines = lines
                .OrderBy(l => l.PoLineNumber)
                .Select(l => new PlanOrderLineDto
                {
                    PoLineId = l.PoLineId,
                    PoLineNumber = l.PoLineNumber,
                    ItemId = l.ItemId,
                    ItemCode = l.ItemCode,
                    ItemName = l.ItemName,
                    Model = l.Model,
                    OrderedBase = l.OrderedBase,
                    AvailableBase = Math.Max(0, l.AvailableBase),
                    PlannedBase = 0,
                    PcsPerContainer = l.PcPerContainer,
                    CapacitySource = l.PcPerContainer is null ? "None" : "Item Definition",
                    CapacityMessage = l.PcPerContainer is null && l.AvailableBase > 0
                        ? $"Line {l.PoLineNumber} ({l.ItemCode}): {MissingContainerUnit}"
                        : null,
                    ContainersNeeded = l.PcPerContainer is > 0 && l.AvailableBase > 0
                        ? Math.Round((decimal)l.AvailableBase / l.PcPerContainer.Value, 2)
                        : 0,
                    OilIncluded = l.ItemOilQtyPerUnit > 0,
                })
                .ToList(),
        };
    }

    /// <summary>
    /// THE RIGHTS FIRST, THEN THE SHAPE, THEN SQL: the override and the confirmation are refused
    /// before anything is created, and a plan the procedure would refuse halfway is refused here with
    /// the container's place in the list ("Container 3 of 30: ..."), which is how the page numbers them.
    /// Over capacity comes back like a single save: 409 OVER_CAPACITY with data.canOverride.
    /// </summary>
    public async Task<Result<IReadOnlyList<CreatedContainerDto>>> CreateFromPlanAsync(
        CreateContainersFromPlanRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.Create))
        {
            return Forbidden<IReadOnlyList<CreatedContainerDto>>(Permissions.Containers.Create);
        }

        var canOverride = permissions.Contains(Permissions.Containers.OverCapacity);
        if (request.AllowOverCapacity && !canOverride)
        {
            return Result<IReadOnlyList<CreatedContainerDto>>.Failure(
                ErrorType.Forbidden,
                $"Creating containers above their capacity needs the {Permissions.Containers.OverCapacity} permission.",
                "FORBIDDEN");
        }

        if (request.Confirm && !permissions.Contains(Permissions.Containers.Confirm))
        {
            return Result<IReadOnlyList<CreatedContainerDto>>.Failure(
                ErrorType.Forbidden,
                $"Confirming the new containers needs the {Permissions.Containers.Confirm} permission.",
                "FORBIDDEN");
        }

        if (request.ShippingMethod is not null && ShippingMethods.Normalize(request.ShippingMethod) is null)
        {
            return Result<IReadOnlyList<CreatedContainerDto>>.Failure(
                ErrorType.Validation, "Shipping method must be Sea, Air or Road.", "VALIDATION");
        }

        if (CheckPlan(request.Containers) is { } invalid)
        {
            return Result<IReadOnlyList<CreatedContainerDto>>.Failure(ErrorType.Validation, invalid, "VALIDATION");
        }

        IReadOnlyList<CreatedContainerDto> created;
        try
        {
            created = await _containers.CreateBatchAsync(request, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return failure.Code == "OVER_CAPACITY"
                ? Result<IReadOnlyList<CreatedContainerDto>>.Failure(failure.Type, failure.Message, failure.Code, new { canOverride })
                : Result<IReadOnlyList<CreatedContainerDto>>.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("{Count} container(s) created from the plan of order {PurchaseOrderId} by user {UserId}{Confirmed}{Override}",
            created.Count, request.PurchaseOrderId, userId,
            request.Confirm ? " (confirmed)" : string.Empty,
            request.AllowOverCapacity ? " (over capacity confirmed)" : string.Empty);
        return Result<IReadOnlyList<CreatedContainerDto>>.Success(created);
    }

    /// <summary>
    /// Both numbers are sent for every container and both are written, so an empty value is a clear:
    /// trimmed here, empty becomes null. A number typed twice or used by another container is the
    /// procedure's 69013 (409 DUPLICATE_CONTAINER_NO): it alone sees the other containers.
    /// </summary>
    public async Task<Result<IReadOnlyList<ContainerNumberDto>>> SetNumbersAsync(
        ContainerNumbersRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.Create))
        {
            return Forbidden<IReadOnlyList<ContainerNumberDto>>(Permissions.Containers.Create);
        }

        if (request.Items is null or { Count: 0 })
        {
            return NumbersInvalid("Select at least one container.");
        }

        if (request.Items.FirstOrDefault(i => i.ContainerId <= 0) is not null)
        {
            return NumbersInvalid("Every row needs its containerId.");
        }

        if (request.Items.GroupBy(i => i.ContainerId).FirstOrDefault(g => g.Count() > 1) is { } twice)
        {
            return NumbersInvalid($"Container {twice.Key} appears more than once.");
        }

        var items = request.Items
            .Select(i => new ContainerNumberRequest
            {
                ContainerId = i.ContainerId,
                ContainerNo = Cleaned(i.ContainerNo)?.ToUpperInvariant(),
                SealNo = Cleaned(i.SealNo),
            })
            .ToList();

        if (items.FirstOrDefault(i => i.ContainerNo is { Length: > 20 }) is { } longNo)
        {
            return NumbersInvalid($"Container number {longNo.ContainerNo} is longer than 20 characters.");
        }

        if (items.FirstOrDefault(i => i.SealNo is { Length: > 30 }) is { } longSeal)
        {
            return NumbersInvalid($"Seal number {longSeal.SealNo} is longer than 30 characters.");
        }

        IReadOnlyList<ContainerNumberDto> saved;
        try
        {
            saved = await _containers.SetNumbersAsync(items, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<ContainerNumberDto>>(ex);
        }

        _logger.LogInformation("Numbers of {Count} container(s) saved by user {UserId}", saved.Count, userId);
        return Result<IReadOnlyList<ContainerNumberDto>>.Success(saved);
    }

    public async Task<Result<IReadOnlyList<ContainerConfirmedDto>>> ConfirmManyAsync(
        IdsRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.Confirm))
        {
            return Forbidden<IReadOnlyList<ContainerConfirmedDto>>(Permissions.Containers.Confirm);
        }

        if (CheckIds(request) is { } invalid)
        {
            return Result<IReadOnlyList<ContainerConfirmedDto>>.Failure(ErrorType.Validation, invalid, "VALIDATION");
        }

        IReadOnlyList<ContainerConfirmedDto> rows;
        try
        {
            rows = await _containers.ConfirmManyAsync(request.Ids, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<ContainerConfirmedDto>>(ex);
        }

        _logger.LogInformation("{Confirmed} of {Count} selected container(s) confirmed by user {UserId}",
            rows.Count(r => r.ConfirmedNow), rows.Count, userId);
        return Result<IReadOnlyList<ContainerConfirmedDto>>.Success(rows);
    }

    public async Task<Result<ContainersDeletedDto>> DeleteManyAsync(
        IdsRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.Delete))
        {
            return Forbidden<ContainersDeletedDto>(Permissions.Containers.Delete);
        }

        if (CheckIds(request) is { } invalid)
        {
            return Result<ContainersDeletedDto>.Failure(ErrorType.Validation, invalid, "VALIDATION");
        }

        int deleted;
        try
        {
            deleted = await _containers.DeleteManyAsync(request.Ids, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ContainersDeletedDto>(ex);
        }

        _logger.LogInformation("{Count} container(s) deleted by user {UserId}", deleted, userId);
        return Result<ContainersDeletedDto>.Success(new ContainersDeletedDto { Deleted = deleted });
    }

    /// <summary>
    /// Containers numbered 1..N in the order shown, every one with a line; within a container an
    /// order line at most once and every quantity above zero. The plan table's primary key
    /// (Seq, PoLineId) would refuse a line twice too, but as a constraint violation — a 500.
    /// </summary>
    internal static string? CheckPlan(IReadOnlyList<PlanContainerRequest>? containers)
    {
        if (containers is null || containers.All(c => c.Lines is null or { Count: 0 }))
        {
            return "The plan has no container with a line to create.";
        }

        var total = containers.Count;
        if (total > MaxContainersPerPlan)
        {
            return $"At most {MaxContainersPerPlan} containers can be created at once; the plan has {total}.";
        }

        for (var position = 1; position <= total; position++)
        {
            var container = containers[position - 1];
            var name = $"Container {position} of {total}";

            if (container.Seq != position)
            {
                return $"{name}: the containers must be numbered 1 to {total} in the order shown (seq {container.Seq} was sent).";
            }

            if (container.Lines is null or { Count: 0 })
            {
                return $"{name}: it has no line. Remove it from the plan or add a line.";
            }

            if (container.Lines.FirstOrDefault(l => l.PoLineId <= 0) is not null)
            {
                return $"{name}: every line needs its order line (poLineId).";
            }

            if (container.Lines.FirstOrDefault(l => l.QuantityBase <= 0) is { } empty)
            {
                return $"{name}: the quantity of order line {empty.PoLineId} must be greater than zero.";
            }

            if (container.Lines.GroupBy(l => l.PoLineId).FirstOrDefault(g => g.Count() > 1) is { } twice)
            {
                return $"{name}: order line {twice.Key} appears more than once.";
            }
        }

        return null;
    }

    private static string? CheckIds(IdsRequest request)
    {
        if (request.Ids is null or { Count: 0 })
        {
            return "Select at least one container.";
        }

        return request.Ids.Any(id => id <= 0) ? "A container id must be greater than zero." : null;
    }

    private static Result<IReadOnlyList<ContainerNumberDto>> NumbersInvalid(string message)
        => Result<IReadOnlyList<ContainerNumberDto>>.Failure(ErrorType.Validation, message, "VALIDATION");

    private static string? Cleaned(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    /* ── export ───────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var read = await GetAsync(id, permissions, cancellationToken);
        if (read.IsFailure || read.Value is null)
        {
            return Result<(byte[], string)>.Failure(read.ErrorType, read.Error ?? NotFoundMessage, read.Code ?? "NOT_FOUND");
        }

        var container = read.Value;
        return Result<(byte[], string)>.Success((BuildWorkbook(container), $"Container_{container.ContainerRef}.xlsx"));
    }

    /// <summary>
    /// Three sheets, the way the forwarder's file is read: the container (identification, shipping,
    /// B/L, capacity, cost, operations), the invoices covering it, and the lines loaded — with the
    /// real cost of each item (FOB, charges and landed per unit) and what was received once it has
    /// been offloaded.
    /// </summary>
    private static byte[] BuildWorkbook(ContainerDto container)
    {
        using var workbook = new XLWorkbook();

        var sheet = workbook.AddWorksheet("Container");
        sheet.Cell(1, 1).Value = $"Container {container.ContainerRef}";
        sheet.Cell(1, 1).Style.Font.Bold = true;
        sheet.Cell(1, 1).Style.Font.FontSize = 14;

        var header = new (string Label, string Value)[]
        {
            ("Container Ref.", container.ContainerRef),
            ("Container No.", container.ContainerNo ?? string.Empty),
            ("Container Type", $"{container.ContainerTypeCode} - {container.ContainerTypeName}"),
            ("Status", container.StatusName),
            ("Current Location", container.CurrentLocation ?? string.Empty),
            ("Seal No.", container.SealNo ?? string.Empty),
            ("Customs Seal No.", container.CustomsSealNo ?? string.Empty),
            ("Order Date", Day(container.OrderDate)),
            ("Order Month", container.OrderMonth),
            ("Purchase Order", container.PurchaseOrderNumber ?? string.Empty),
            ("Suppliers", string.Join(", ", container.Suppliers.Select(s => s.SupplierName))),
            ("Shipping Method", container.ShippingMethod),
            ("Country of Origin", container.CountryOfOrigin ?? string.Empty),
            ("Forwarder", container.ForwarderName ?? string.Empty),
            ("Transporter", container.TransporterName ?? string.Empty),
            ("Line / Carrier", container.ShippingLine ?? string.Empty),
            ("Vessel / Voyage", $"{container.VesselName} {container.VoyageNo}".Trim()),
            ("Booking No.", container.BookingNo ?? string.Empty),
            ("Port of Loading", container.PortOfLoadingName ?? string.Empty),
            ("Port of Destination", container.PortOfDestinationName ?? string.Empty),
            ("Final Destination", container.FinalDestinationName ?? string.Empty),
            ("Dispatch Date", Day(container.DispatchDate)),
            ("ETA", Day(container.Eta)),
            ("Actual Port Arrival", Day(container.ActualPortArrival)),
            ("Free Days / Last Free Day", container.FreeDays is null ? string.Empty : $"{container.FreeDays} / {Day(container.LastFreeDay)}"),
            ("B/L No.", container.BlNo ?? string.Empty),
            ("B/L Date", Day(container.BlDate)),
            ("Customs Release", Day(container.CustomsReleaseDate)),
            ("Declaration No.", container.DeclarationNo ?? string.Empty),
            ("FERI No.", container.FeriNo ?? string.Empty),
            ("Truck / Waybill", $"{container.TruckNo} {container.WaybillNo}".Trim()),
            ("Branch", $"{container.BranchCode} - {container.BranchName}"),
            ("Offloading Warehouse", container.WarehouseName ?? string.Empty),
            ("Offloaded", Day(container.OffloadedDate)),
            ("Allocated Units", container.TotalAllocatedBase.ToString()),
            ("Fill", container.FillPct is { } pct
                ? $"{pct:0.##} %"
                : container.MissingContainerUnitItems is { } missing ? $"Unknown: no Container unit for {missing}" : string.Empty),
            ("Total Oil", container.TotalOilQty.ToString("0.##")),
            ("Invoiced (posted / draft)", $"{container.InvoicedPostedBase} / {container.InvoicedDraftBase}"),
            ("FOB Total (base)", container.FobTotalBase?.ToString("#,##0.00") ?? string.Empty),
            ("Charges Posted (base)", container.ChargesPostedBase.ToString("#,##0.00")),
            ("Charges Draft (base)", container.ChargesDraftBase.ToString("#,##0.00")),
            ("Landed Total (base)", container.LandedTotalBase?.ToString("#,##0.00") ?? string.Empty),
            ("Notes", container.Notes ?? string.Empty),
        };

        var row = 3;
        foreach (var (label, value) in header)
        {
            sheet.Cell(row, 1).Value = label;
            sheet.Cell(row, 1).Style.Font.Bold = true;
            sheet.Cell(row, 2).Value = value;
            row++;
        }

        sheet.Columns().AdjustToContents();

        WriteTable(workbook.AddWorksheet("Invoices"),
            ["PI No.", "PI Date", "Status", "Order", "Supplier", "Commercial Invoice No.", "Exporter Ref.", "Currency", "Qty in Container", "Amount in Container", "Amount in Container (base)"],
            container.Invoices.Select(i => new XLCellValue[]
            {
                i.DocumentNumber ?? "DRAFT", Day(i.DocumentDate), InvoiceStatusName(i.InvoiceStatus), i.PurchaseOrderNumber ?? string.Empty,
                i.SupplierName, i.CommercialInvoiceNo ?? string.Empty, i.ExporterReference ?? string.Empty, i.CurrencyCode,
                i.QtyInContainerBase, i.AmountInContainer, i.AmountInContainerBase,
            }));

        WriteTable(workbook.AddWorksheet("Lines"),
            ["#", "PO No.", "Supplier", "Item Code", "Item Name", "Model", "Qty (pcs)", "Invoiced (posted)", "Invoiced (draft)", "PI No.",
             "FOB / Unit", "FOB Source", "Charges", "Charges / Unit", "Landed / Unit", "Landed Final", "Oil", "Oil / Unit", "Total Oil",
             "Received (pcs)", "Variance Reason", "Notes"],
            container.Lines.Select(l => new XLCellValue[]
            {
                l.LineNumber, l.PurchaseOrderNumber ?? string.Empty, l.SupplierName, l.ItemCode, l.ItemName, l.Model ?? string.Empty,
                l.QuantityBase, l.InvoicedPostedBase, l.InvoicedDraftBase, l.InvoiceNumbers ?? string.Empty,
                Money(l.UnitFobBase), l.FobSource, l.ChargesBase, Money(l.ChargesPerUnitBase), Money(l.LandedCostBase),
                l.IsLandedFinal ? "Yes" : "Estimate",
                l.OilIncluded ? "Yes" : "No", l.OilQtyPerUnit is { } oil ? oil : Blank.Value, l.TotalOilQty,
                l.ReceivedQuantityBase is { } received ? received : Blank.Value,
                l.VarianceReason ?? string.Empty, l.Notes ?? string.Empty,
            }));

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private static void WriteTable(IXLWorksheet sheet, string[] columns, IEnumerable<XLCellValue[]> rows)
    {
        for (var i = 0; i < columns.Length; i++)
        {
            sheet.Cell(1, i + 1).Value = columns[i];
        }

        var headerRange = sheet.Range(1, 1, 1, columns.Length);
        headerRange.Style.Font.Bold = true;
        headerRange.Style.Fill.BackgroundColor = XLColor.FromArgb(0xE8, 0xEE, 0xF7);
        headerRange.Style.Border.BottomBorder = XLBorderStyleValues.Thin;

        var row = 1;
        foreach (var values in rows)
        {
            row++;
            for (var i = 0; i < values.Length; i++)
            {
                sheet.Cell(row, i + 1).Value = values[i];
            }
        }

        sheet.Columns().AdjustToContents();
    }

    private static string Day(DateTime? value) => value?.ToString("dd/MM/yyyy") ?? string.Empty;

    /// <summary>Per-unit costs rounded to the cent for the sheet; the page keeps the full precision.</summary>
    private static XLCellValue Money(decimal? value) => value is { } v ? Math.Round(v, 2) : Blank.Value;

    private static string InvoiceStatusName(byte status) => status switch
    {
        1 => "Draft",
        2 => "Posted",
        3 => "Cancelled",
        4 => "Closed",
        _ => status.ToString(),
    };

    /* ── the shared shapes ────────────────────────────────────────────────────────────────────── */

    private async Task<Result<ContainerDto>> ReadAsync(int id, CancellationToken cancellationToken)
    {
        var container = await _containers.GetAsync(id, cancellationToken);
        return container is null
            ? Result<ContainerDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<ContainerDto>.Success(container);
    }

    /// <summary>
    /// Permission, then the procedure, then a re-read: a confirm moves the derived status, an offload
    /// writes the received quantities and freezes the costs — the answer is the server's container,
    /// not a patch of what was sent.
    /// </summary>
    private async Task<Result<ContainerDto>> ChangeAsync(
        int id, string permission, IReadOnlySet<string> permissions, int userId, string verb,
        CancellationToken cancellationToken, Func<Task> change)
    {
        if (!permissions.Contains(permission))
        {
            return Forbidden<ContainerDto>(permission);
        }

        try
        {
            await change();
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ContainerDto>(ex);
        }

        _logger.LogInformation("Container {ContainerId} {Verb} by user {UserId}", id, verb, userId);
        return await ReadAsync(id, cancellationToken);
    }
}
