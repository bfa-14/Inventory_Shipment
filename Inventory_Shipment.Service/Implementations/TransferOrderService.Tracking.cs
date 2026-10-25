using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory.Transfers;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Service.Excel;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// (93) BATCH, SERIAL AND EXPIRY ON TRANSFERS (script 93, chapter 5).
/// <list type="bullet">
///   <item>THE RULES ARE THE DATABASE'S: format, length, duplicates, sums and "already on the way" are
///   fn_TransferDispatch_TrackingProblems' (the dialog's Check and the posting read the same rows, so a sentence shown at
///   Done is the sentence the posting would refuse with); the receipt's rows are the receive core's. This service only
///   refuses a runaway request of more than 10,000 rows before the database (B14) and a dispatch row named twice in one
///   receipt (the type's key), and maps 62016 / 62017 to 400 TRANSFER_TRACKING / 409 SERIAL_ON_THE_WAY.</item>
///   <item>NO NEW PERMISSION (B11): Check and the suggestions come with Dispatch Transfers, the rows of a posting with
///   View Transfer Orders. The read routes need no warehouse check (W3); a dispatch is checked by 92 like any.</item>
///   <item>THE ROWS ARE READ PER POSTING (B18): the order's Get carries per posting line only the kind and the count.</item>
/// </list>
/// </summary>
public sealed partial class TransferOrderService
{
    /// <summary>62016 and the service's own ceiling refusals.</summary>
    private const string TrackingCode = "TRANSFER_TRACKING";

    public async Task<Result<CheckDispatchTrackingResult>> CheckDispatchTrackingAsync(
        int id, DispatchTransferRequest request, int? forLineId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersDispatch))
        {
            return Forbidden<CheckDispatchTrackingResult>(Permissions.Inventory.TransfersDispatch);
        }

        if (EmptyDispatchRows<CheckDispatchTrackingResult>(request) is { } emptyRow)
        {
            return emptyRow;
        }

        if ((request.Lines ?? []).GroupBy(l => l.TransferOrderLineId).Any(g => g.Count() > 1))
        {
            return Result<CheckDispatchTrackingResult>.Failure(
                ErrorType.Validation, "Each line of the order may appear only once in a dispatch.", "VALIDATION");
        }

        // A runaway paste is answered as the database's first rule would answer it (Seq 5), without sending it there.
        if (TrackingRowCount(request) > TransferTrackingRules.MaxRows)
        {
            return Result<CheckDispatchTrackingResult>.Success(new CheckDispatchTrackingResult
            {
                Problems =
                [
                    new TransferTrackingProblemDto
                    {
                        Seq = 5, Severity = TransferTrackingSeverities.Error, Message = TransferTrackingRules.TooManyDispatchRows,
                    },
                ],
                ErrorCount = 1,
            });
        }

        IReadOnlyList<TransferTrackingProblemDto> problems;
        try
        {
            problems = await _transfers.CheckDispatchTrackingAsync(id, request.Lines, forLineId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<CheckDispatchTrackingResult>(ex);
        }

        return Result<CheckDispatchTrackingResult>.Success(new CheckDispatchTrackingResult
        {
            Problems = problems,
            ErrorCount = problems.Count(p => p.Severity == TransferTrackingSeverities.Error),
            WarningCount = problems.Count(p => p.Severity == TransferTrackingSeverities.Warning),
        });
    }

    public async Task<Result<IReadOnlyList<TransferTrackingRowDto>>> PostingTrackingAsync(
        int id, int postingId, bool onTheWayOnly, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersView))
        {
            return Forbidden<IReadOnlyList<TransferTrackingRowDto>>(Permissions.Inventory.TransfersView);
        }

        // Posting ids are sequential across every order: one that is not this order's is "not found", never another's rows.
        if (await _transfers.PostingOrderIdAsync(postingId, cancellationToken) != id)
        {
            return Result<IReadOnlyList<TransferTrackingRowDto>>.Failure(ErrorType.NotFound, PostingNotFoundMessage, "NOT_FOUND");
        }

        try
        {
            return Result<IReadOnlyList<TransferTrackingRowDto>>.Success(
                await _transfers.PostingTrackingAsync(postingId, onTheWayOnly, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<TransferTrackingRowDto>>(ex);
        }
    }

    public async Task<Result<TransferTrackingSuggestionsDto>> TrackingSuggestionsAsync(
        int id, int transferOrderLineId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersDispatch))
        {
            return Forbidden<TransferTrackingSuggestionsDto>(Permissions.Inventory.TransfersDispatch);
        }

        TransferTrackingSuggestionsDto? suggestions;
        try
        {
            suggestions = await _transfers.TrackingSuggestionsAsync(id, transferOrderLineId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferTrackingSuggestionsDto>(ex);
        }

        // A line that is not on the order is the procedure's 62006 (its own sentence, 404, through Failure above);
        // a null answer is kept as the same 404 should a reader ever return none.
        return suggestions is null
            ? Result<TransferTrackingSuggestionsDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<TransferTrackingSuggestionsDto>.Success(suggestions);
    }

    /* ── the request's own guards ─────────────────────────────────────────────────────────────── */

    /// <summary>
    /// AN EMPTY ROW OF THE REQUEST - "lines": [null] or "tracking": [null] - is refused before anything reads it: 400
    /// VALIDATION, never a 500 (script 90's rule for its lines, "Line {n} of the request is empty.", carried to the
    /// tracking rows). {n} is the line's place in the request, 1-based.
    /// </summary>
    private static Result<T>? EmptyDispatchRows<T>(DispatchTransferRequest request)
    {
        var lines = request.Lines ?? [];
        for (var i = 0; i < lines.Count; i++)
        {
            if (lines[i] is null)
            {
                return Result<T>.Failure(ErrorType.Validation, $"Line {i + 1} of the request is empty.", "VALIDATION");
            }

            if (lines[i].Tracking?.Any(r => r is null) == true)
            {
                return Result<T>.Failure(ErrorType.Validation, $"Line {i + 1} of the request has an empty batch, serial or expiry row.", "VALIDATION");
            }
        }

        return null;
    }

    /// <inheritdoc cref="EmptyDispatchRows{T}"/>
    private static Result<TransferPostedResult>? EmptyReceiptRows(ReceiveTransferRequest request)
    {
        var lines = request.Lines ?? [];
        for (var i = 0; i < lines.Count; i++)
        {
            if (lines[i] is null)
            {
                return Result<TransferPostedResult>.Failure(ErrorType.Validation, $"Line {i + 1} of the request is empty.", "VALIDATION");
            }

            if (lines[i].Tracking?.Any(r => r is null) == true)
            {
                return Result<TransferPostedResult>.Failure(
                    ErrorType.Validation, $"Line {i + 1} of the request has an empty batch, serial or expiry row.", "VALIDATION");
            }
        }

        return null;
    }

    private static int TrackingRowCount(DispatchTransferRequest request)
        => (request.Lines ?? []).Sum(l => l.Tracking?.Count ?? 0);

    /// <summary>B14 before the database: a dispatch (or dispatch and receive) of more than 10,000 tracking rows.</summary>
    private static Result<T>? TooManyDispatchRows<T>(DispatchTransferRequest request)
        => TrackingRowCount(request) > TransferTrackingRules.MaxRows
            ? Result<T>.Failure(ErrorType.Validation, TransferTrackingRules.TooManyDispatchRows, TrackingCode)
            : null;

    /// <summary>
    /// B14 for a receipt, then the type's key: one dispatch row named twice (on one line or two) could never be one row of
    /// inventory.tvp_TransferReceiptTracking, so it is refused here with a sentence instead of a key violation.
    /// </summary>
    private static Result<TransferPostedResult>? ReceiptTrackingRefusal(ReceiveTransferRequest request)
    {
        var rows = (request.Lines ?? []).SelectMany(l => l.Tracking ?? []).ToList();
        if (rows.Count > TransferTrackingRules.MaxRows)
        {
            return Result<TransferPostedResult>.Failure(ErrorType.Validation, TransferTrackingRules.TooManyReceiptRows, TrackingCode);
        }

        return rows.GroupBy(r => r.DispatchTrackingId).Any(g => g.Count() > 1)
            ? Result<TransferPostedResult>.Failure(ErrorType.Validation, TransferTrackingRules.DuplicateReceiptRow, "VALIDATION")
            : null;
    }

    /// <summary>
    /// ROWS UNDER A LINE THAT LEFT WITHOUT THEM. The receipt type carries no line (5.3.4): the database matches each row
    /// to its dispatch line by the row itself, while the line's receivedBase is the sum of the rows sent UNDER it
    /// (5.5.4). A row put under a line that left without rows would so turn that line's pieces into the row's (0 for a
    /// lost serial: the line silently not received, or all of it written off with "Nothing more will arrive"), so such
    /// a line is refused here with the database's own sentence for it (62000). Rows moved between two tracked lines
    /// need no guard: their received pieces make both sums differ from the rows (62016), and a lost-only row counts on
    /// its own line. One read of the order (kinds and counts only, B18), only when a line carries rows.
    /// </summary>
    private async Task<Result<TransferPostedResult>?> RowsUnderUntrackedLineAsync(
        int id, ReceiveTransferRequest request, int userId, CancellationToken cancellationToken)
    {
        var withRows = (request.Lines ?? []).Where(l => l.Tracking is { Count: > 0 }).ToList();
        if (withRows.Count == 0)
        {
            return null;
        }

        var order = await _transfers.GetAsync(id, userId, cancellationToken);
        if (order is null)
        {
            return null;    // the procedure's own "not found"
        }

        var dispatchLines = order.Postings
            .Where(p => p.Kind == TransferPostingKinds.Dispatch)
            .SelectMany(p => p.Lines.Select(l => (Posting: p, Line: l)))
            .ToDictionary(x => x.Line.Id);
        foreach (var line in withRows)
        {
            if (dispatchLines.TryGetValue(line.DispatchLineId, out var d) && d.Line.TrackingKind is null)
            {
                return Result<TransferPostedResult>.Failure(ErrorType.Validation,
                    $"{d.Posting.DocumentNumber} line {d.Line.LineNumber} ({d.Line.ItemCode}) left without batch, serial or expiry details: receive it without them.",
                    "VALIDATION");
            }
        }

        return null;
    }

    /// <summary>
    /// The export's sheet "Batch, serial and expiry": the rows of every posting with a tracked line, read posting by
    /// posting through the same procedure as the page (none for an order without tracking: its export is 90's).
    /// </summary>
    private async Task<IReadOnlyList<TransferPostingTracking>> TrackingForExportAsync(
        TransferOrderDto order, CancellationToken cancellationToken)
    {
        var sheets = new List<TransferPostingTracking>();
        foreach (var posting in order.Postings.Where(p => p.Lines.Any(l => l.TrackingCount > 0)))
        {
            try
            {
                var rows = await _transfers.PostingTrackingAsync(posting.Id, onTheWayOnly: false, cancellationToken);
                if (rows.Count > 0)
                {
                    sheets.Add(new TransferPostingTracking(posting, rows));
                }
            }
            catch (BusinessRuleException ex)
            {
                // A posting read a moment ago cannot vanish (postings are never deleted); should it, the sheet goes without it.
                _logger.LogWarning(ex, "Transfer order {TransferOrderId}: the tracking rows of posting {PostingId} could not be read for the export",
                    order.Id, posting.Id);
            }
        }

        return sheets;
    }
}
