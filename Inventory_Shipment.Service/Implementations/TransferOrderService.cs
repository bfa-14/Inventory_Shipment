using System.Globalization;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Inventory.Transfers;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Excel;
using Inventory_Shipment.Service.Interfaces;
using Inventory_Shipment.Service.Security;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Transfer orders (script 90): stock moved between two leaf warehouses of any branch, through the hidden "On the way"
/// warehouse of the destination branch, without changing its cost.
///
/// THE RULES ARE THE PROCEDURES'. Every refusal is the first row of inventory.fn_TransferOrder_Blocks for the action, or
/// the action's own check, thrown with its sentence; the page's disabled buttons read the same rows from the GET. This
/// service checks the permission (ten verbs, inventory.transfers.*), shapes the request into the table types, answers
/// the procedure's refusal as it comes with a code, and re-reads the order after every action: the answer is the
/// server's document, never a patch of what was sent.
///
/// VALUES ARE A PERMISSION, NOT A SCREEN (FB decision 21): without inventory.costs.view (View item costs, script 94;
/// inventory.valuation.view before it) every value figure leaves as null - never 0, which would read as a measured zero -
/// and the export leaves its value columns out.
///
/// THE APPROVAL EMAILS (<see cref="ITransferApprovalMailer"/>) are queued after the procedure decided, outside its
/// transaction; a failure becomes the answer's emailWarning, never the action's failure.
/// </summary>
public sealed partial class TransferOrderService : ITransferOrderService
{
    private const string NotFoundMessage = "Transfer order not found.";
    private const string PostingNotFoundMessage = "Dispatch or receipt not found.";
    private const string ForbiddenCode = "FORBIDDEN";

    /// <summary>
    /// A row version that is sent but cannot be one (not 8 bytes of base64, or a "+" turned into a space in a query
    /// string): refused, never read as "not sent" - which would skip the concurrency check (script 82's rule).
    /// </summary>
    private const string InvalidRowVersionMessage = "The row version is not valid. Reload the page and try again.";

    /// <summary>
    /// THE WORK AFTER THE COMMIT never stops halfway: once a procedure has decided, the order is re-read and the approval
    /// emails queued even when the caller has gone (a closed tab, a proxy's timeout) - an aborted read would turn an
    /// action that took place into a 499, and an aborted mailer would lose the emails the audit says were sent (2.5.4).
    /// </summary>
    private static readonly CancellationToken AfterCommit = CancellationToken.None;

    /// <summary>The page's own type: the import's unit preference (Inventory: the base unit) and its "Document Type" check.</summary>
    private const string TransferOrderTypeCode = "TRO";

    private static readonly CultureInfo Numbers = CultureInfo.InvariantCulture;

    private readonly ITransferOrderRepository _transfers;
    private readonly IWarehouseRepository _warehouses;
    private readonly IInvoiceImportRepository _imports;
    private readonly InvoiceImportParser _parser;
    private readonly ITransferApprovalMailer _mailer;
    private readonly IWarehouseAccessService _access;
    private readonly SalesOptions _salesOptions;
    private readonly ILogger<TransferOrderService> _logger;

    public TransferOrderService(
        ITransferOrderRepository transfers,
        IWarehouseRepository warehouses,
        IInvoiceImportRepository imports,
        InvoiceImportParser parser,
        ITransferApprovalMailer mailer,
        IWarehouseAccessService access,
        IOptions<SalesOptions> salesOptions,
        ILogger<TransferOrderService> logger)
    {
        _transfers = transfers;
        _warehouses = warehouses;
        _imports = imports;
        _parser = parser;
        _mailer = mailer;
        _access = access;
        _salesOptions = salesOptions.Value;
        _logger = logger;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<TransferOrderListResult>> SearchAsync(
        TransferOrderQuery query, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersView))
        {
            return Forbidden<TransferOrderListResult>(Permissions.Inventory.TransfersView);
        }

        try
        {
            var (items, totalCount, totals) = await _transfers.SearchAsync(query, userId, cancellationToken);
            return Result<TransferOrderListResult>.Success(new TransferOrderListResult
            {
                Items = items,
                TotalCount = totalCount,
                Page = Math.Max(query.Page, 1),
                PageSize = Math.Clamp(query.PageSize, 1, 200),
                Totals = totals,
            });
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferOrderListResult>(ex);
        }
    }

    /// <summary>
    /// The menu count. A reader who may not approve gets 0 waiting for approval: that part is the approvers' to-do list.
    /// (92) A reader who may receive gets the transfers on the way to their own warehouses beside it (0 for a reader with
    /// All warehouses: the count is for once users have their own warehouses, FB section 6).
    /// </summary>
    public async Task<Result<TransferWaitingDto>> WaitingAsync(
        int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersView))
        {
            return Forbidden<TransferWaitingDto>(Permissions.Inventory.TransfersView);
        }

        var count = permissions.Contains(Permissions.Inventory.TransfersApprove)
            ? await _transfers.WaitingCountAsync(userId, cancellationToken)
            : 0;
        var toReceive = permissions.Contains(Permissions.Inventory.TransfersReceive)
            ? await _transfers.ToReceiveCountAsync(userId, cancellationToken)
            : 0;
        return Result<TransferWaitingDto>.Success(new TransferWaitingDto { WaitingForApproval = count, ToReceive = toReceive });
    }

    public async Task<Result<IReadOnlyList<TransferAvailabilityDto>>> AvailabilityAsync(
        TransferAvailabilityQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersCreate))
        {
            return Forbidden<IReadOnlyList<TransferAvailabilityDto>>(Permissions.Inventory.TransfersCreate);
        }

        if (query.FromWarehouseId is not > 0 || query.ToWarehouseId is not > 0)
        {
            return Result<IReadOnlyList<TransferAvailabilityDto>>.Failure(
                ErrorType.Validation, "fromWarehouseId and toWarehouseId are required.", "VALIDATION");
        }

        var itemIds = new List<int>();
        foreach (var part in (query.ItemIds ?? string.Empty).Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (!int.TryParse(part, NumberStyles.None, Numbers, out var itemId) || itemId <= 0)
            {
                return Result<IReadOnlyList<TransferAvailabilityDto>>.Failure(
                    ErrorType.Validation, "itemIds must be item ids separated by commas.", "VALIDATION");
            }

            itemIds.Add(itemId);
        }

        try
        {
            var rows = await _transfers.AvailabilityAsync(
                query.FromWarehouseId.Value, query.ToWarehouseId.Value, itemIds.Distinct().ToList(), query.ExcludeOrderId, cancellationToken);
            return Result<IReadOnlyList<TransferAvailabilityDto>>.Success(rows);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<TransferAvailabilityDto>>(ex);
        }
    }

    public async Task<Result<TransferOrderDto>> GetAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => permissions.Contains(Permissions.Inventory.TransfersView)
            ? await ReadAsync(id, userId, permissions, cancellationToken)
            : Forbidden<TransferOrderDto>(Permissions.Inventory.TransfersView);

    /* ── the draft ────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<TransferOrderDto>> SaveAsync(
        int? id, SaveTransferOrderRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersCreate))
        {
            return Forbidden<TransferOrderDto>(Permissions.Inventory.TransfersCreate);
        }

        if (BadRequest<TransferOrderDto>(request.RowVersion, request.Lines) is { } bad)
        {
            return bad;
        }

        int savedId;
        try
        {
            savedId = await _transfers.SaveAsync(id, request, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferOrderDto>(ex);
        }

        _logger.LogInformation("Transfer order {TransferOrderId} saved by user {UserId}", savedId, userId);
        return await ReadAsync(savedId, userId, permissions, AfterCommit);
    }

    public async Task<Result<TransferOrderDto>> UpdateDetailsAsync(
        int id, UpdateTransferDetailsRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersCreate))
        {
            return Forbidden<TransferOrderDto>(Permissions.Inventory.TransfersCreate);
        }

        if (BadRequest<TransferOrderDto>(request.RowVersion) is { } bad)
        {
            return bad;
        }

        try
        {
            await _transfers.UpdateDetailsAsync(id, request, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferOrderDto>(ex);
        }

        return await ReadAsync(id, userId, permissions, AfterCommit);
    }

    public async Task<Result> DeleteAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersDelete))
        {
            return ForbiddenResult(Permissions.Inventory.TransfersDelete);
        }

        if (InvalidRowVersion(rowVersion))
        {
            return Result.Failure(ErrorType.Validation, InvalidRowVersionMessage, "VALIDATION");
        }

        try
        {
            await _transfers.DeleteAsync(id, ToRowVersion(rowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return FailureResult(ex);
        }

        _logger.LogInformation("Transfer order {TransferOrderId} deleted by user {UserId}", id, userId);
        return Result.Success();
    }

    /* ── release and approval ─────────────────────────────────────────────────────────────────── */

    public async Task<Result<TransferActionResult>> ReleaseAsync(
        int id, TransferRowVersionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersRelease))
        {
            return Forbidden<TransferActionResult>(Permissions.Inventory.TransfersRelease);
        }

        IReadOnlyList<string> warnings;
        if (BadRequest<TransferActionResult>(request.RowVersion) is { } bad)
        {
            return bad;
        }

        try
        {
            warnings = await _transfers.ReleaseAsync(id, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferActionResult>(ex);
        }

        return await ActionAsync(id, userId, permissions, order => $"{Name(order)} released.", warnings, null);
    }

    public async Task<Result<TransferActionResult>> SendForApprovalAsync(
        int id, TransferRowVersionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersRelease))
        {
            return Forbidden<TransferActionResult>(Permissions.Inventory.TransfersRelease);
        }

        IReadOnlyList<TransferApproverDto> approvers;
        if (BadRequest<TransferActionResult>(request.RowVersion) is { } bad)
        {
            return bad;
        }

        try
        {
            approvers = await _transfers.SendForApprovalAsync(id, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferActionResult>(ex);
        }

        var read = await ReadAsync(id, userId, permissions, AfterCommit);
        if (read.IsFailure || read.Value is null)
        {
            return Result<TransferActionResult>.Failure(read.ErrorType, read.Error ?? NotFoundMessage, read.Code ?? "NOT_FOUND");
        }

        var order = read.Value;
        var emailWarning = await _mailer.ApprovalRequestedAsync(order, approvers, order.Approval.RequestedByName, userId, AfterCommit);
        _logger.LogInformation("Transfer order {TransferOrderId} sent for approval by user {UserId}: {Count} approver(s) to tell",
            id, userId, approvers.Count);

        return Result<TransferActionResult>.Success(new TransferActionResult
        {
            Order = order,
            Message = $"{Name(order)} sent for approval.",
            EmailWarning = emailWarning,
        });
    }

    public async Task<Result<TransferActionResult>> ApproveAsync(
        int id, TransferRowVersionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersApprove))
        {
            return Forbidden<TransferActionResult>(Permissions.Inventory.TransfersApprove);
        }

        IReadOnlyList<string> warnings;
        TransferRequesterDto? requester;
        if (BadRequest<TransferActionResult>(request.RowVersion) is { } bad)
        {
            return bad;
        }

        try
        {
            (warnings, requester) = await _transfers.ApproveAsync(id, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferActionResult>(ex);
        }

        var read = await ReadAsync(id, userId, permissions, AfterCommit);
        if (read.IsFailure || read.Value is null)
        {
            return Result<TransferActionResult>.Failure(read.ErrorType, read.Error ?? NotFoundMessage, read.Code ?? "NOT_FOUND");
        }

        var order = read.Value;
        var emailWarning = await _mailer.ApprovedAsync(order, requester, userId, userId, AfterCommit);
        return Result<TransferActionResult>.Success(new TransferActionResult
        {
            Order = order,
            Message = $"{Name(order)} approved and released.",
            Warnings = warnings,
            EmailWarning = emailWarning,
        });
    }

    public async Task<Result<TransferActionResult>> RejectAsync(
        int id, TransferReasonRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersApprove))
        {
            return Forbidden<TransferActionResult>(Permissions.Inventory.TransfersApprove);
        }

        TransferRequesterDto? requester;
        if (BadRequest<TransferActionResult>(request.RowVersion) is { } bad)
        {
            return bad;
        }

        try
        {
            requester = await _transfers.RejectAsync(id, ToRowVersion(request.RowVersion), request.Reason, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferActionResult>(ex);
        }

        var read = await ReadAsync(id, userId, permissions, AfterCommit);
        if (read.IsFailure || read.Value is null)
        {
            return Result<TransferActionResult>.Failure(read.ErrorType, read.Error ?? NotFoundMessage, read.Code ?? "NOT_FOUND");
        }

        var order = read.Value;
        var reason = order.Approval.RejectReason ?? request.Reason?.Trim() ?? string.Empty;
        var emailWarning = await _mailer.RejectedAsync(order, requester, userId, reason, userId, AfterCommit);
        return Result<TransferActionResult>.Success(new TransferActionResult
        {
            Order = order,
            Message = $"{Name(order)} rejected: back to draft.",
            EmailWarning = emailWarning,
        });
    }

    public async Task<Result<TransferActionResult>> WithdrawAsync(
        int id, TransferRowVersionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersRelease))
        {
            return Forbidden<TransferActionResult>(Permissions.Inventory.TransfersRelease);
        }

        if (BadRequest<TransferActionResult>(request.RowVersion) is { } bad)
        {
            return bad;
        }

        try
        {
            await _transfers.WithdrawAsync(id, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferActionResult>(ex);
        }

        return await ActionAsync(id, userId, permissions, order => $"{Name(order)} withdrawn: back to draft.", [], null);
    }

    public async Task<Result<TransferActionResult>> BackToDraftAsync(
        int id, TransferReasonRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersRelease))
        {
            return Forbidden<TransferActionResult>(Permissions.Inventory.TransfersRelease);
        }

        if (BadRequest<TransferActionResult>(request.RowVersion) is { } bad)
        {
            return bad;
        }

        try
        {
            await _transfers.BackToDraftAsync(id, ToRowVersion(request.RowVersion), request.Reason, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferActionResult>(ex);
        }

        return await ActionAsync(id, userId, permissions, order => $"{Name(order)} is a draft again.", [], null);
    }

    /* ── dispatch and receipt ─────────────────────────────────────────────────────────────────── */

    public async Task<Result<TransferPostedResult>> DispatchAsync(
        int id, DispatchTransferRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersDispatch))
        {
            return Forbidden<TransferPostedResult>(Permissions.Inventory.TransfersDispatch);
        }

        if (BadRequest<TransferPostedResult>(request.RowVersion, request.Lines) is { } bad)
        {
            return bad;
        }

        // (93) An empty tracking row ("tracking": [null]), then one line twice, then more than 10,000 tracking rows.
        if ((EmptyDispatchRows<TransferPostedResult>(request) ?? DuplicateDispatchLines(request) ?? TooManyDispatchRows<TransferPostedResult>(request)) is { } refusal)
        {
            return refusal;
        }

        TransferPostedRefDto posted;
        try
        {
            posted = await _transfers.DispatchAsync(id, request, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferPostedResult>(ex);
        }

        _logger.LogInformation("Transfer order {TransferOrderId}: dispatch {DocumentNumber} posted by user {UserId}",
            id, posted.DocumentNumber, userId);

        return await PostedAsync(id, userId, permissions, [posted], order =>
        {
            var dispatch = Posting(order, posted);
            return $"{dispatch?.DocumentNumber ?? posted.DocumentNumber} posted: {Pcs(dispatch?.TotalQuantityBase ?? 0)} pcs left {order.From.Code}.";
        });
    }

    public async Task<Result<TransferPostedResult>> ReceiveAsync(
        int id, ReceiveTransferRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersReceive))
        {
            return Forbidden<TransferPostedResult>(Permissions.Inventory.TransfersReceive);
        }

        if (BadRequest<TransferPostedResult>(request.RowVersion, request.Lines) is { } bad)
        {
            return bad;
        }

        // (93) An empty tracking row ("tracking": [null]) before anything reads it.
        if (EmptyReceiptRows(request) is { } emptyRow)
        {
            return emptyRow;
        }

        // The type's key is the dispatch line: two rows for one line would break it, so the request is refused first.
        var lines = request.Lines ?? [];
        if (lines.GroupBy(l => l.DispatchLineId).Any(g => g.Count() > 1))
        {
            return Result<TransferPostedResult>.Failure(
                ErrorType.Validation, "Each dispatch line may appear only once in a receipt.", "VALIDATION");
        }

        // (93) The tracking rows: at most 10,000, each dispatch row once (the receipt type's key).
        if ((ReceiptTrackingRefusal(request) ?? await RowsUnderUntrackedLineAsync(id, request, userId, cancellationToken)) is { } trackingRefusal)
        {
            return trackingRefusal;
        }

        TransferPostedRefDto posted;
        try
        {
            posted = await _transfers.ReceiveAsync(id, request, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferPostedResult>(ex);
        }

        _logger.LogInformation("Transfer order {TransferOrderId}: receipt {DocumentNumber} posted by user {UserId}",
            id, posted.DocumentNumber, userId);

        return await PostedAsync(id, userId, permissions, [posted], order =>
        {
            var receipt = Posting(order, posted);
            var lost = receipt?.TotalLostBase ?? 0;
            return $"{receipt?.DocumentNumber ?? posted.DocumentNumber} posted: {Pcs(receipt?.TotalQuantityBase ?? 0)} pcs received into {order.To.Code}"
                   + (lost > 0 ? $"; {Pcs(lost)} pcs written off" : string.Empty) + ".";
        });
    }

    public async Task<Result<TransferPostedResult>> DispatchAndReceiveAsync(
        int id, DispatchTransferRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        // BOTH RIGHTS (FB decision 17): it is a dispatch and a receipt, posted together or not at all.
        if (!permissions.Contains(Permissions.Inventory.TransfersDispatch))
        {
            return Forbidden<TransferPostedResult>(Permissions.Inventory.TransfersDispatch);
        }

        if (!permissions.Contains(Permissions.Inventory.TransfersReceive))
        {
            return Forbidden<TransferPostedResult>(Permissions.Inventory.TransfersReceive);
        }

        if (BadRequest<TransferPostedResult>(request.RowVersion, request.Lines) is { } bad)
        {
            return bad;
        }

        // (93) An empty tracking row ("tracking": [null]), then one line twice, then more than 10,000 tracking rows.
        if ((EmptyDispatchRows<TransferPostedResult>(request) ?? DuplicateDispatchLines(request) ?? TooManyDispatchRows<TransferPostedResult>(request)) is { } refusal)
        {
            return refusal;
        }

        TransferPostedRefDto dispatch;
        TransferPostedRefDto receipt;
        try
        {
            (dispatch, receipt) = await _transfers.DispatchAndReceiveAsync(id, request, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferPostedResult>(ex);
        }

        _logger.LogInformation("Transfer order {TransferOrderId}: {Dispatch} and {Receipt} posted together by user {UserId}",
            id, dispatch.DocumentNumber, receipt.DocumentNumber, userId);

        return await PostedAsync(id, userId, permissions, [dispatch, receipt], order =>
        {
            // The receipt of the pair points at its dispatch: found by that link when the answer did not name it.
            var sent = Posting(order, dispatch);
            var arrived = Posting(order, receipt)
                          ?? order.Postings.FirstOrDefault(p => p.Kind == TransferPostingKinds.Receipt && p.PostedWithId == dispatch.Id);
            return $"{sent?.DocumentNumber ?? dispatch.DocumentNumber} and {arrived?.DocumentNumber ?? receipt.DocumentNumber} posted: "
                   + $"{Pcs(sent?.TotalQuantityBase ?? 0)} pcs moved from {order.From.Code} to {order.To.Code}.";
        });
    }

    /* ── close, cancel, reverse, ETA, return ──────────────────────────────────────────────────── */

    public async Task<Result<TransferActionResult>> NothingMoreSentAsync(
        int id, TransferReasonRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersClose))
        {
            return Forbidden<TransferActionResult>(Permissions.Inventory.TransfersClose);
        }

        if (BadRequest<TransferActionResult>(request.RowVersion) is { } bad)
        {
            return bad;
        }

        try
        {
            await _transfers.NothingMoreSentAsync(id, ToRowVersion(request.RowVersion), request.Reason, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferActionResult>(ex);
        }

        return await ActionAsync(id, userId, permissions,
            order => $"Nothing more will be sent on {Name(order)}: {Pcs(order.Totals.NotSentBase)} pcs not sent.", [], null);
    }

    public async Task<Result<TransferActionResult>> CancelAsync(
        int id, TransferReasonRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersCancel))
        {
            return Forbidden<TransferActionResult>(Permissions.Inventory.TransfersCancel);
        }

        if (BadRequest<TransferActionResult>(request.RowVersion) is { } bad)
        {
            return bad;
        }

        try
        {
            await _transfers.CancelAsync(id, ToRowVersion(request.RowVersion), request.Reason, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferActionResult>(ex);
        }

        return await ActionAsync(id, userId, permissions, order => $"{Name(order)} cancelled.", [], null);
    }

    public async Task<Result<TransferActionResult>> ReversePostingAsync(
        int id, int postingId, ReverseTransferPostingRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersReverse))
        {
            return Forbidden<TransferActionResult>(Permissions.Inventory.TransfersReverse);
        }

        if (await PostingOfAsync(id, postingId, cancellationToken) is { } notFound)
        {
            return notFound;
        }

        if (BadRequest<TransferActionResult>(request.RowVersion) is { } bad)
        {
            return bad;
        }

        try
        {
            await _transfers.ReversePostingAsync(postingId, ToRowVersion(request.RowVersion), request.Reason, request.Date, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferActionResult>(ex);
        }

        _logger.LogInformation("Transfer order {TransferOrderId}: posting {PostingId} reversed by user {UserId}", id, postingId, userId);
        return await ActionAsync(id, userId, permissions,
            order => $"{order.Postings.FirstOrDefault(p => p.Id == postingId)?.DocumentNumber ?? "The posting"} reversed.", [], null);
    }

    public async Task<Result<TransferActionResult>> ChangeEtaAsync(
        int id, int postingId, ChangeTransferEtaRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersDispatch))
        {
            return Forbidden<TransferActionResult>(Permissions.Inventory.TransfersDispatch);
        }

        if (await PostingOfAsync(id, postingId, cancellationToken) is { } notFound)
        {
            return notFound;
        }

        if (BadRequest<TransferActionResult>(request.RowVersion) is { } bad)
        {
            return bad;
        }

        try
        {
            await _transfers.SetEtaAsync(postingId, ToRowVersion(request.RowVersion), request.Eta, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferActionResult>(ex);
        }

        return await ActionAsync(id, userId, permissions, order =>
        {
            var dispatch = order.Postings.FirstOrDefault(p => p.Id == postingId);
            return $"{dispatch?.DocumentNumber ?? "The dispatch"}: ETA {dispatch?.Eta?.ToString("dd/MM/yyyy", Numbers) ?? request.Eta?.ToString("dd/MM/yyyy", Numbers)}.";
        }, [], null);
    }

    public async Task<Result<TransferOrderDto>> CreateReturnAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersCreate))
        {
            return Forbidden<TransferOrderDto>(Permissions.Inventory.TransfersCreate);
        }

        int newId;
        try
        {
            newId = await _transfers.CreateReturnAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferOrderDto>(ex);
        }

        _logger.LogInformation("Transfer order {TransferOrderId}: return {ReturnId} created by user {UserId}", id, newId, userId);
        return await ReadAsync(newId, userId, permissions, AfterCommit);
    }

    /* ── import and export ────────────────────────────────────────────────────────────────────── */

    public Result<(byte[] Content, string FileName)> ImportTemplate(IReadOnlySet<string> permissions)
        => permissions.Contains(Permissions.Inventory.TransfersCreate)
            ? Result<(byte[], string)>.Success((TransferOrderWorkbooks.GenerateTemplate(), TransferOrderWorkbooks.TemplateFileName))
            : Forbidden<(byte[], string)>(Permissions.Inventory.TransfersCreate);

    /// <summary>
    /// THE STOCK IMPORT'S ENGINE IN A TRANSFER MODE (2.5.5). The file is read by <see cref="InvoiceImportParser"/> and
    /// judged by sales.usp_InvoiceImport_Validate like every document import, against the order's From (its branch, From
    /// as the default warehouse, no price list, no stock check, the type TRO: a blank Unit is the base unit, an exact
    /// barcode takes its unit, a row naming another type is an Error). Two things the import of other documents accepts
    /// a transfer refuses before the database, row by row: a Warehouse (the order's From and To are every line's) and a
    /// Unit Price / Cost (a transfer moves no cost). Nothing is saved: the page appends the usable rows to its draft.
    /// </summary>
    public async Task<Result<ImportValidationResult>> ValidateImportAsync(
        Stream file, string fileName, long fileLength, int? fromWarehouseId, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersCreate))
        {
            return Forbidden<ImportValidationResult>(Permissions.Inventory.TransfersCreate);
        }

        if (fromWarehouseId is not > 0)
        {
            return Result<ImportValidationResult>.Failure(
                ErrorType.Validation, "Choose the warehouse the goods leave from.", "VALIDATION");
        }

        if (fileLength <= 0)
        {
            return InvalidFile("The file is empty.");
        }

        if (fileLength > InvoiceImportParser.MaxFileBytes)
        {
            return InvalidFile($"The file is larger than {InvoiceImportParser.MaxFileBytes / (1024 * 1024)} MB.");
        }

        if (!fileName.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase))
        {
            return InvalidFile("Only .xlsx files can be imported. Save the file as an Excel workbook and try again.");
        }

        IReadOnlyList<InvoiceImportRow> rows;
        try
        {
            rows = _parser.Parse(file);
        }
        catch (InvoiceImportFileException ex)
        {
            return InvalidFile(ex.Message);
        }

        if (rows.Count == 0)
        {
            return InvalidFile("The file has no rows to import.");
        }

        var from = await _warehouses.GetByIdAsync(fromWarehouseId.Value, cancellationToken);
        if (from is null)
        {
            return Result<ImportValidationResult>.Failure(ErrorType.Validation, "The warehouse was not found.", "VALIDATION");
        }

        // (92) The order is the source's document: its lines are imported only by someone who may use the From (A9).
        if (await _access.RefusalAsync(userId, [from.Id], cancellationToken: cancellationToken) is { } refusal)
        {
            return WarehouseAccess.Failure<ImportValidationResult>(refusal);
        }

        // A transfer's own refusals, before the database: the row keeps its number and says what to leave empty.
        var refused = new List<InvoiceImportValidatedRow>();
        var toValidate = new List<InvoiceImportRow>();
        foreach (var row in rows)
        {
            var problems = new List<string>();
            if (!string.IsNullOrWhiteSpace(row.WarehouseRef))
            {
                problems.Add("A transfer takes its warehouses from the order: leave Warehouse empty.");
            }

            if (row.UnitPrice is not null || !string.IsNullOrWhiteSpace(row.RawUnitPrice))
            {
                problems.Add("A transfer has no cost: leave Unit Price empty.");
            }

            if (problems.Count == 0)
            {
                toValidate.Add(row);
                continue;
            }

            refused.Add(new InvoiceImportValidatedRow
            {
                RowNumber = row.RowNumber,
                Status = InvoiceImportStatus.Error,
                Message = string.Join(" ", problems),
                RowDocumentTypeCode = string.IsNullOrWhiteSpace(row.DocumentTypeCode) ? TransferOrderTypeCode : row.DocumentTypeCode,
                ItemRef = row.ItemRef,
                Quantity = row.Quantity is { } quantity && quantity == decimal.Truncate(quantity) && quantity is >= int.MinValue and <= int.MaxValue
                    ? (int)quantity
                    : null,
                Notes = row.Notes,
            });
        }

        IReadOnlyList<InvoiceImportValidatedRow> validated = [];
        if (toValidate.Count > 0)
        {
            try
            {
                validated = await _imports.ValidateAsync(
                    from.BranchId, from.Id, priceListId: null, allowPriceOverride: false, _salesOptions.MaxDiscountPercent,
                    checkStock: false, TransferOrderTypeCode, toValidate, cancellationToken);
            }
            catch (BusinessRuleException ex)
            {
                // As the document import: the header's trouble (the From warehouse) is MASTER_INACTIVE, anything else the file's.
                var code = ex.Number == SqlErrors.InvoiceImportMasterInactive ? "MASTER_INACTIVE" : "INVALID_FILE";
                return Result<ImportValidationResult>.Failure(ErrorType.Validation, ex.Message, code);
            }
        }

        var all = validated.Concat(refused).OrderBy(r => r.RowNumber).ToList();
        _logger.LogInformation(
            "Transfer import validated {FileName} for warehouse {WarehouseId}: {Total} rows, {Refused} refused before the database.",
            fileName, from.Id, all.Count, refused.Count);

        return Result<ImportValidationResult>.Success(new ImportValidationResult
        {
            FileName = fileName,
            TotalRows = all.Count,
            ValidRows = all.Count(r => r.Status == InvoiceImportStatus.Valid),
            WarningRows = all.Count(r => r.Status == InvoiceImportStatus.Warning),
            ErrorRows = all.Count(r => r.Status == InvoiceImportStatus.Error),
            Rows = all,
        });
    }

    public async Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var read = await GetAsync(id, userId, permissions, cancellationToken);
        if (read.IsFailure || read.Value is null)
        {
            return Result<(byte[], string)>.Failure(read.ErrorType, read.Error ?? NotFoundMessage, read.Code ?? "NOT_FOUND");
        }

        // (94) The value columns: View item costs (View Stock Valuation before script 94).
        var withValues = ItemCosts.Sees(permissions);
        // (93) The sheet "Batch, serial and expiry": the rows of each posting that carries any, read posting by posting.
        var tracking = await TrackingForExportAsync(read.Value, cancellationToken);
        return Result<(byte[], string)>.Success(
            (TransferOrderWorkbooks.BuildExport(read.Value, withValues, tracking), TransferOrderWorkbooks.ExportFileName(read.Value)));
    }

    /* ── files ────────────────────────────────────────────────────────────────────────────────── */

    /// <summary>Files as on the goods receipts: added, edited and deleted with the create right, in any status.</summary>
    public async Task<Result<int>> AddFileAsync(
        int id, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersCreate))
        {
            return Forbidden<int>(Permissions.Inventory.TransfersCreate);
        }

        try
        {
            return Result<int>.Success(await _transfers.AddFileAsync(id, fileName, contentType, content, fields, userId, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<int>(ex);
        }
    }

    public async Task<Result<IReadOnlyList<DocumentFileDto>>> ListFilesAsync(
        int id, int? attachmentTypeId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersView))
        {
            return Forbidden<IReadOnlyList<DocumentFileDto>>(Permissions.Inventory.TransfersView);
        }

        if (!await _transfers.ExistsAsync(id, cancellationToken))
        {
            return Result<IReadOnlyList<DocumentFileDto>>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND");
        }

        return Result<IReadOnlyList<DocumentFileDto>>.Success(
            await _transfers.ListFilesAsync(id, attachmentTypeId, cancellationToken: cancellationToken));
    }

    public async Task<Result<TransferOrderFileContent>> GetFileAsync(
        int id, int fileId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersView))
        {
            return Forbidden<TransferOrderFileContent>(Permissions.Inventory.TransfersView);
        }

        var file = await _transfers.GetFileAsync(fileId, cancellationToken);

        // Checked against the order in the route: file ids are sequential across every order.
        return file is null || file.DocumentId != id
            ? Result<TransferOrderFileContent>.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND")
            : Result<TransferOrderFileContent>.Success(file);
    }

    public async Task<Result<DocumentFileDto>> UpdateFileAsync(
        int id, int fileId, DocumentFileEdit edit, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersCreate))
        {
            return Forbidden<DocumentFileDto>(Permissions.Inventory.TransfersCreate);
        }

        if ((await _transfers.ListFilesAsync(id, fileId: fileId, cancellationToken: cancellationToken)).Count == 0)
        {
            return Result<DocumentFileDto>.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND");
        }

        try
        {
            var file = await _transfers.UpdateFileAsync(fileId, edit, userId, cancellationToken);
            return file is null
                ? Result<DocumentFileDto>.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND")
                : Result<DocumentFileDto>.Success(file);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<DocumentFileDto>(ex);
        }
    }

    public async Task<Result> DeleteFileAsync(
        int id, int fileId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersCreate))
        {
            return ForbiddenResult(Permissions.Inventory.TransfersCreate);
        }

        var file = await _transfers.GetFileAsync(fileId, cancellationToken);
        if (file is null || file.DocumentId != id)
        {
            return Result.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND");
        }

        try
        {
            await _transfers.DeleteFileAsync(fileId, userId, cancellationToken);
            return Result.Success();
        }
        catch (BusinessRuleException ex)
        {
            return FailureResult(ex);
        }
    }

    /* ── the shared shapes ────────────────────────────────────────────────────────────────────── */

    /// <summary>The order as this reader may see it (values stripped without the permission), or 404.</summary>
    private async Task<Result<TransferOrderDto>> ReadAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken)
    {
        var order = await _transfers.GetAsync(id, userId, cancellationToken);
        return order is null
            ? Result<TransferOrderDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<TransferOrderDto>.Success(WithValuesFor(order, permissions));
    }

    /// <summary>The answer of an action that moved no stock: the order re-read (after the commit: <see cref="AfterCommit"/>), the message, the warnings.</summary>
    private async Task<Result<TransferActionResult>> ActionAsync(
        int id, int userId, IReadOnlySet<string> permissions, Func<TransferOrderDto, string> message,
        IReadOnlyList<string> warnings, string? emailWarning)
    {
        var read = await ReadAsync(id, userId, permissions, AfterCommit);
        if (read.IsFailure || read.Value is null)
        {
            return Result<TransferActionResult>.Failure(read.ErrorType, read.Error ?? NotFoundMessage, read.Code ?? "NOT_FOUND");
        }

        return Result<TransferActionResult>.Success(new TransferActionResult
        {
            Order = read.Value,
            Message = message(read.Value),
            Warnings = warnings,
            EmailWarning = emailWarning,
        });
    }

    /// <summary>The answer of a posting: the order re-read (after the commit: <see cref="AfterCommit"/>), the postings made, the message.</summary>
    private async Task<Result<TransferPostedResult>> PostedAsync(
        int id, int userId, IReadOnlySet<string> permissions, IReadOnlyList<TransferPostedRefDto> postings,
        Func<TransferOrderDto, string> message)
    {
        var read = await ReadAsync(id, userId, permissions, AfterCommit);
        if (read.IsFailure || read.Value is null)
        {
            return Result<TransferPostedResult>.Failure(read.ErrorType, read.Error ?? NotFoundMessage, read.Code ?? "NOT_FOUND");
        }

        var order = read.Value;

        // The numbers as the order now reads them: an answer that lacked one (a receipt's) is completed from the order.
        var made = postings.Select(p =>
        {
            var found = Posting(order, p)
                        ?? (p.Kind == TransferPostingKinds.Receipt && postings.Count > 1
                            ? order.Postings.FirstOrDefault(x => x.Kind == TransferPostingKinds.Receipt && x.PostedWithId == postings[0].Id)
                            : null);
            return found is null ? p : new TransferPostedRefDto { Id = found.Id, Kind = found.Kind, DocumentNumber = found.DocumentNumber };
        }).ToList();

        return Result<TransferPostedResult>.Success(new TransferPostedResult
        {
            Order = order,
            Postings = made,
            Message = message(order),
        });
    }

    /// <summary>The posting of the order a write answered with: by id, else by number.</summary>
    private static TransferPostingDto? Posting(TransferOrderDto order, TransferPostedRefDto posted)
        => order.Postings.FirstOrDefault(p => posted.Id > 0 && p.Id == posted.Id)
           ?? order.Postings.FirstOrDefault(p => posted.DocumentNumber.Length > 0 && p.DocumentNumber == posted.DocumentNumber);

    /// <summary>404 "Dispatch or receipt not found." when the posting is not one of the order in the route; null when it is.</summary>
    private async Task<Result<TransferActionResult>?> PostingOfAsync(int id, int postingId, CancellationToken cancellationToken)
        => await _transfers.PostingOrderIdAsync(postingId, cancellationToken) == id
            ? null
            : Result<TransferActionResult>.Failure(ErrorType.NotFound, PostingNotFoundMessage, "NOT_FOUND");

    /// <summary>The type's key is the order line: one line listed twice in a dispatch is refused before the database.</summary>
    private static Result<TransferPostedResult>? DuplicateDispatchLines(DispatchTransferRequest request)
        => (request.Lines ?? []).GroupBy(l => l.TransferOrderLineId).Any(g => g.Count() > 1)
            ? Result<TransferPostedResult>.Failure(ErrorType.Validation, "Each line of the order may appear only once in a dispatch.", "VALIDATION")
            : null;

    /// <summary>
    /// The order as a reader without the value permission may see it: every value figure null - the value on the way,
    /// the postings' values and lost values, the lines' frozen and loss costs - never 0. Stripped here, once, on the way
    /// out (the SalesInvoiceService.WithCostsFor pattern), so no page can draw what it was not given.
    /// </summary>
    internal static TransferOrderDto WithValuesFor(TransferOrderDto order, IReadOnlySet<string> permissions)
    {
        // (94) Who sees the value figures (cost frozen at dispatch, the value on the way, losses): View item costs, the
        // permission of every item cost (View Stock Valuation before script 94; every role holding it was granted this).
        if (ItemCosts.Sees(permissions))
        {
            return order;
        }

        return order with
        {
            OnTheWayValueBase = null,
            Postings = order.Postings.Select(p => p with
            {
                ValueBase = null,
                LostValueBase = null,
                Lines = p.Lines.Select(l => l with { UnitCostBase = null, LossUnitCostBase = null }).ToList(),
            }).ToList(),
        };
    }

    /// <summary>"TRO-BR-003-000012", or "The transfer order" while it has no number (TRO numbered at release).</summary>
    private static string Name(TransferOrderDto order)
        => string.IsNullOrWhiteSpace(order.DocumentNumber) ? "The transfer order" : order.DocumentNumber;

    private static string Pcs(int pieces) => pieces.ToString("N0", Numbers);

    private static Result<T> Forbidden<T>(string permission)
        => Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", ForbiddenCode);

    private static Result ForbiddenResult(string permission)
        => Result.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", ForbiddenCode);

    private static Result<ImportValidationResult> InvalidFile(string message)
        => Result<ImportValidationResult>.Failure(ErrorType.Validation, message, "INVALID_FILE");

    private static Result<T> Failure<T>(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result<T>.Failure(failure.Type, failure.Message, failure.Code);
    }

    private static Result FailureResult(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result.Failure(failure.Type, failure.Message, failure.Code);
    }

    /// <summary>
    /// The procedures' THROWs, classified (2.3.15), as StockDocumentService.Describe: the block 62xxx is shared with the
    /// stock documents, four numbers are the transfers' own. THE MESSAGE IS ALWAYS THE PROCEDURE'S - "Line 1
    /// (TVS-APACHE-160): 50 pcs dispatched but only 44 are left to dispatch." names the line and the numbers - and only the
    /// code is added, so the page can react without reading English: 400 for what the request got wrong, 403 for an
    /// approval by a user who may not approve, 404 for an order that does not exist, 409 for the state of the world.
    /// </summary>
    internal static RuleFailure Describe(BusinessRuleException exception) => exception.Number switch
    {
        // (92) fn_TransferOrder_Blocks' access rows, Save's From and the ledger trigger: the user may not use that warehouse.
        SqlErrors.WarehouseAccessDenied => new RuleFailure(ErrorType.Forbidden, exception.Message, Security.WarehouseAccess.Code),
        SqlErrors.StockDocumentValidation => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
        SqlErrors.StockDocumentConcurrency => new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY"),
        SqlErrors.StockDocumentNotDraft => new RuleFailure(ErrorType.Conflict, exception.Message, "NOT_DRAFT"),
        SqlErrors.StockDocumentNotFound => new RuleFailure(ErrorType.NotFound, exception.Message, "NOT_FOUND"),
        SqlErrors.StockDocumentInsufficientStock => new RuleFailure(ErrorType.Conflict, exception.Message, "INSUFFICIENT_STOCK"),
        SqlErrors.StockDocumentMasterInactive => new RuleFailure(ErrorType.Validation, exception.Message, "MASTER_INACTIVE"),
        SqlErrors.StockDocumentNoLines => new RuleFailure(ErrorType.Validation, exception.Message, "NO_LINES"),
        // Also the dispatch lock not obtained in 30 s ("Another dispatch from LKS-01 is being posted. Try again in a moment."), as 63010.
        SqlErrors.StockDocumentInvalidStatus => new RuleFailure(ErrorType.Conflict, exception.Message, "INVALID_STATUS"),
        SqlErrors.StockDocumentAttachmentType => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
        SqlErrors.TransferMoreThanRemains => new RuleFailure(ErrorType.Validation, exception.Message, "MORE_THAN_REMAINS"),
        SqlErrors.TransferReverseLaterFirst => new RuleFailure(ErrorType.Conflict, exception.Message, "REVERSE_LATER_FIRST"),
        SqlErrors.TransferNeedsApproval => new RuleFailure(ErrorType.Conflict, exception.Message, "NEEDS_APPROVAL"),
        SqlErrors.TransferNotApprover => new RuleFailure(ErrorType.Forbidden, exception.Message, "NOT_APPROVER"),
        SqlErrors.WarehouseSystemManaged => new RuleFailure(ErrorType.Conflict, exception.Message, "SYSTEM_WAREHOUSE"),
        // (93) Batch, serial or expiry rows refused (the line, the row, what to do), and a serial no. already on the way.
        SqlErrors.TransferTracking => new RuleFailure(ErrorType.Validation, exception.Message, TrackingCode),
        SqlErrors.TransferSerialOnTheWay => new RuleFailure(ErrorType.Conflict, exception.Message, "SERIAL_ON_THE_WAY"),
        _ => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),
    };

    /// <summary>
    /// What the request got wrong before any database call (400 VALIDATION): a row version that cannot be one, or an
    /// empty row (null) in its lines - "lines": [null] passes the model binding (it checks properties, not the elements of
    /// a list) and would otherwise end in a NullReferenceException and a 500.
    /// </summary>
    private static Result<T>? BadRequest<T>(string? rowVersion, IEnumerable<object?>? lines = null)
    {
        if (InvalidRowVersion(rowVersion))
        {
            return Result<T>.Failure(ErrorType.Validation, InvalidRowVersionMessage, "VALIDATION");
        }

        var position = 0;
        foreach (var line in lines ?? [])
        {
            position++;
            if (line is null)
            {
                return Result<T>.Failure(ErrorType.Validation, $"Line {position} of the request is empty.", "VALIDATION");
            }
        }

        return null;
    }

    private static bool InvalidRowVersion(string? value) => !string.IsNullOrWhiteSpace(value) && ToRowVersion(value) is null;

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

    internal readonly record struct RuleFailure(ErrorType Type, string Message, string Code);
}
