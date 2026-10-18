using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using static Inventory_Shipment.Service.Implementations.LogisticsRuleFailures;

namespace Inventory_Shipment.Service.Implementations;

public sealed partial class MovementService : IMovementService
{
    private const string NotFoundMessage = "Movement not found.";

    /// <summary>The procedure's page ceiling; the export walks the pages at this size.</summary>
    private const int ExportPageSize = 200;

    /// <summary>
    /// The page ceiling of logistics.usp_Movement_ContainerCandidates: 5,000 since script 78 (200 before), so the movement's
    /// list holds every candidate at its From in one call - each page costs the whole place check.
    /// </summary>
    private const int CandidatePageSize = 5000;

    /// <summary>The width of a value of logistics.tvp_TextList.</summary>
    private const int MaxNumberLength = 100;

    private const string FromRequiredMessage = "Choose the From first.";

    private readonly IMovementRepository _movements;
    private readonly ILogger<MovementService> _logger;

    public MovementService(IMovementRepository movements, ILogger<MovementService> logger)
    {
        _movements = movements;
        _logger = logger;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<PagedResult<MovementListDto>>> SearchAsync(
        MovementQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.MovementsView))
        {
            return Forbidden<PagedResult<MovementListDto>>(Permissions.Containers.MovementsView);
        }

        if (InvalidStatus(query) is { } invalid)
        {
            return Result<PagedResult<MovementListDto>>.Failure(ErrorType.Validation, invalid, "VALIDATION");
        }

        var (items, totalCount) = await _movements.SearchAsync(query, cancellationToken);

        return Result<PagedResult<MovementListDto>>.Success(new PagedResult<MovementListDto>
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<MovementDto>> GetAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        // The Movements screen, or a container's page showing the movements it travels with (script 75).
        if (!permissions.Contains(Permissions.Containers.MovementsView) && !permissions.Contains(Permissions.Containers.View))
        {
            return Forbidden<MovementDto>(Permissions.Containers.MovementsView);
        }

        return await ReadAsync(id, cancellationToken);
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<MovementDto>> SaveAsync(
        int? id, SaveMovementRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.MovementsManage))
        {
            return Forbidden<MovementDto>(Permissions.Containers.MovementsManage);
        }

        if (request.ContainerIds.Count == 0)
        {
            return Result<MovementDto>.Failure(ErrorType.Validation, "Select at least one container.", "VALIDATION");
        }

        int savedId;
        try
        {
            savedId = await _movements.SaveAsync(request, id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<MovementDto>(ex);
        }

        _logger.LogInformation("Movement {MovementId} saved by user {UserId}", savedId, userId);
        return await ReadAsync(savedId, cancellationToken);
    }

    public Task<Result<MovementDto>> StartAsync(
        int id, MovementStatusRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => SetStatusAsync(id, "Start", request, userId, permissions, cancellationToken);

    public Task<Result<MovementDto>> CompleteAsync(
        int id, MovementStatusRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => SetStatusAsync(id, "Complete", request, userId, permissions, cancellationToken);

    public Task<Result<MovementDto>> CancelAsync(
        int id, MovementStatusRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(request.Reason))
        {
            return Task.FromResult(Result<MovementDto>.Failure(
                ErrorType.Validation, "A cancellation reason is required.", "VALIDATION"));
        }

        return SetStatusAsync(id, "Cancel", request, userId, permissions, cancellationToken);
    }

    public async Task<Result> DeleteAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.MovementsManage))
        {
            return Forbidden<MovementDto>(Permissions.Containers.MovementsManage);
        }

        try
        {
            await _movements.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        _logger.LogInformation("Movement {MovementId} deleted by user {UserId}", id, userId);
        return Result.Success();
    }

    /// <summary>
    /// CONFIRMING IS A RIGHT OF ITS OWN: a caller without containers.confirm ships only what is
    /// already confirmed — confirmDrafts goes to the procedure as false, and it refuses a draft by
    /// name ("... is a draft: confirm it first ..."), which says more than a 403 would.
    /// </summary>
    public async Task<Result<ShippedMovementDto>> ShipContainersAsync(
        ShipContainersRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.MovementsManage))
        {
            return Forbidden<ShippedMovementDto>(Permissions.Containers.MovementsManage);
        }

        if (request.ContainerIds is null or { Count: 0 })
        {
            return Result<ShippedMovementDto>.Failure(ErrorType.Validation, "Select at least one container.", "VALIDATION");
        }

        if (request.ContainerIds.Any(id => id <= 0))
        {
            return Result<ShippedMovementDto>.Failure(
                ErrorType.Validation, "A container id must be greater than zero.", "VALIDATION");
        }

        var confirmDrafts = request.ConfirmDrafts && permissions.Contains(Permissions.Containers.Confirm);

        ShippedMovementDto movement;
        try
        {
            movement = await _movements.ShipContainersAsync(request, confirmDrafts, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ShippedMovementDto>(ex);
        }

        _logger.LogInformation("Movement {MovementNo} created for {Count} container(s) by user {UserId}{Started}",
            movement.MovementNo, movement.ContainerCount, userId, request.StartNow ? " and started" : string.Empty);
        return Result<ShippedMovementDto>.Success(movement);
    }

    /* ── containers for a movement: the picker, numbers matched ───────────────────────────────── */

    public async Task<Result<PagedResult<MovementContainerCandidateDto>>> ContainerCandidatesAsync(
        MovementContainerCandidateQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.MovementsManage))
        {
            return Forbidden<PagedResult<MovementContainerCandidateDto>>(Permissions.Containers.MovementsManage);
        }

        if (query.FromPlaceId is null or <= 0)
        {
            return Result<PagedResult<MovementContainerCandidateDto>>.Failure(ErrorType.Validation, FromRequiredMessage, "VALIDATION");
        }

        if (!string.IsNullOrWhiteSpace(query.Status) && ContainerStatus.ToCode(query.Status) is null)
        {
            return Result<PagedResult<MovementContainerCandidateDto>>.Failure(
                ErrorType.Validation,
                "status must be 1-8 or Draft, Confirmed, InTransit, AtPort, Cleared, Offloaded, Closed, Cancelled.", "VALIDATION");
        }

        // Clamped here as the procedure does, so the page numbers of the answer are the ones it used.
        var page = Math.Max(1, query.Page);
        var pageSize = Math.Clamp(query.PageSize, 1, CandidatePageSize);

        IReadOnlyList<MovementContainerCandidateDto> items;
        int totalCount;
        try
        {
            (items, totalCount) = await _movements.ContainerCandidatesAsync(query, page, pageSize, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PagedResult<MovementContainerCandidateDto>>(ex);
        }

        return Result<PagedResult<MovementContainerCandidateDto>>.Success(new PagedResult<MovementContainerCandidateDto>
        {
            Items = items,
            Page = page,
            PageSize = pageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<IReadOnlyList<MovementJoinCandidateDto>>> JoinCandidatesAsync(
        int containerId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.MovementsManage))
        {
            return Forbidden<IReadOnlyList<MovementJoinCandidateDto>>(Permissions.Containers.MovementsManage);
        }

        if (containerId <= 0)
        {
            return Result<IReadOnlyList<MovementJoinCandidateDto>>.Failure(
                ErrorType.Validation, "A container id must be greater than zero.", "VALIDATION");
        }

        try
        {
            return Result<IReadOnlyList<MovementJoinCandidateDto>>.Success(
                await _movements.JoinCandidatesAsync(containerId, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<MovementJoinCandidateDto>>(ex);
        }
    }

    /// <summary>More than 10,000 numbers (500 before script 78) is the procedure's refusal (70000 → 400), with its message.</summary>
    public async Task<Result<IReadOnlyList<MovementContainerMatchDto>>> MatchContainersAsync(
        MatchMovementContainersRequest request, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.MovementsManage))
        {
            return Forbidden<IReadOnlyList<MovementContainerMatchDto>>(Permissions.Containers.MovementsManage);
        }

        if (request.FromPlaceId is not { } fromPlaceId || fromPlaceId <= 0)
        {
            return Result<IReadOnlyList<MovementContainerMatchDto>>.Failure(ErrorType.Validation, FromRequiredMessage, "VALIDATION");
        }

        var numbers = request.Numbers ?? [];
        if (numbers.All(string.IsNullOrWhiteSpace))
        {
            return Result<IReadOnlyList<MovementContainerMatchDto>>.Failure(
                ErrorType.Validation, "Give at least one container number.", "VALIDATION");
        }

        var tooLong = numbers.Select((number, index) => (number, index))
            .FirstOrDefault(n => n.number?.Trim().Length > MaxNumberLength);
        if (tooLong.number is not null)
        {
            return Result<IReadOnlyList<MovementContainerMatchDto>>.Failure(
                ErrorType.Validation,
                $"Row {tooLong.index + 1}: a container number has at most {MaxNumberLength} characters.", "VALIDATION");
        }

        try
        {
            return Result<IReadOnlyList<MovementContainerMatchDto>>.Success(
                await _movements.MatchContainersAsync(
                    request.MovementId, fromPlaceId, numbers, request.ToPlaceId, request.MovementTypeId, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<MovementContainerMatchDto>>(ex);
        }
    }

    /* ── export ───────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        MovementQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.MovementsView))
        {
            return Forbidden<(byte[], string)>(Permissions.Containers.MovementsView);
        }

        if (InvalidStatus(query) is { } invalid)
        {
            return Result<(byte[], string)>.Failure(ErrorType.Validation, invalid, "VALIDATION");
        }

        // The whole filter, not the page on screen: walked at the procedure's ceiling.
        var rows = new List<MovementListDto>();
        for (var page = 1; ; page++)
        {
            var (items, total) = await _movements.SearchAsync(
                new MovementQuery
                {
                    Search = query.Search, Status = query.Status, MovementTypeId = query.MovementTypeId,
                    PlaceId = query.PlaceId, ContainerId = query.ContainerId, CarrierPartyId = query.CarrierPartyId,
                    DateFrom = query.DateFrom, DateTo = query.DateTo, SortBy = query.SortBy, SortDir = query.SortDir,
                    Page = page, PageSize = ExportPageSize,
                },
                cancellationToken);

            rows.AddRange(items);
            if (items.Count < ExportPageSize || rows.Count >= total)
            {
                break;
            }
        }

        return Result<(byte[], string)>.Success((BuildWorkbook(rows), $"Movements_{DateTime.UtcNow:yyyyMMdd}.xlsx"));
    }

    private static byte[] BuildWorkbook(IReadOnlyList<MovementListDto> rows)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Movements");

        string[] columns =
        [
            "Movement No.", "Type", "Stage", "From", "To", "Planned", "Start", "ETA", "End", "Days", "Carrier",
            "Vessel / Truck", "Voyage", "Reference", "Containers", "Container Refs", "Charges (base)", "Documents",
            "Status", "Late",
        ];
        for (var i = 0; i < columns.Length; i++)
        {
            sheet.Cell(1, i + 1).Value = columns[i];
        }

        var headerRange = sheet.Range(1, 1, 1, columns.Length);
        headerRange.Style.Font.Bold = true;
        headerRange.Style.Fill.BackgroundColor = XLColor.FromArgb(0xE8, 0xEE, 0xF7);
        headerRange.Style.Border.BottomBorder = XLBorderStyleValues.Thin;

        var row = 1;
        foreach (var m in rows)
        {
            row++;
            XLCellValue[] values =
            [
                m.MovementNo, m.TypeName, m.Stage, $"{m.FromCode} - {m.FromName}", $"{m.ToCode} - {m.ToName}",
                Day(m.PlannedDate), Day(m.StartDate), Day(m.Eta), Day(m.EndDate),
                m.DurationDays is { } days ? days : Blank.Value,
                m.CarrierName ?? string.Empty, m.VehicleOrVessel ?? string.Empty, m.VoyageNo ?? string.Empty,
                m.Reference ?? string.Empty, m.ContainerCount, m.ContainerRefs ?? string.Empty,
                m.ChargesPostedBase is { } charges ? charges : Blank.Value, m.AttachmentCount,
                m.StatusName, m.IsLate ? "Late" : string.Empty,
            ];
            for (var i = 0; i < values.Length; i++)
            {
                sheet.Cell(row, i + 1).Value = values[i];
            }
        }

        sheet.Columns().AdjustToContents();

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private static string Day(DateTime? value) => value?.ToString("dd/MM/yyyy") ?? string.Empty;

    /* ── the shared shapes ────────────────────────────────────────────────────────────────────── */

    private static string? InvalidStatus(MovementQuery query)
        => !string.IsNullOrWhiteSpace(query.Status) && MovementStatus.ToCode(query.Status) is null
            ? "status must be 1-4 or Planned, InProgress, Completed, Cancelled."
            : null;

    private async Task<Result<MovementDto>> ReadAsync(int id, CancellationToken cancellationToken)
    {
        var movement = await _movements.GetAsync(id, cancellationToken);
        return movement is null
            ? Result<MovementDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<MovementDto>.Success(movement);
    }

    /// <summary>
    /// Permission, the procedure, then a re-read: starting or completing moves the containers'
    /// status, dates and location, and the answer shows them as the database now has them.
    /// </summary>
    private async Task<Result<MovementDto>> SetStatusAsync(
        int id, string action, MovementStatusRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken)
    {
        if (!permissions.Contains(Permissions.Containers.MovementsManage))
        {
            return Forbidden<MovementDto>(Permissions.Containers.MovementsManage);
        }

        MovementSplitUndoneDto? undone;
        try
        {
            undone = await _movements.SetStatusAsync(
                id, action, request.Date, request.Reason, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<MovementDto>(ex);
        }

        _logger.LogInformation("Movement {MovementId}: {Action} by user {UserId}", id, action, userId);

        // A COMPLETION IS COMMITTED: what follows it is finished even if the client has gone (tab closed, page reloaded,
        // connection lost). Cut short by the request's token, the Delivery hook would leave some containers without
        // their draft goods receipt and nobody told. Start and Cancel only re-read: the request's token is fine.
        var afterCommit = action == "Complete" ? CancellationToken.None : cancellationToken;

        var read = await ReadAsync(id, afterCommit);

        // (82) A CANCEL THAT UNDID A SPLIT says where the containers went: the procedure's own row, read in its transaction.
        if (undone is not null && read.Value is { } cancelled)
        {
            _logger.LogInformation("Movement {MovementNo} cancelled: the split undone, {Count} container(s) back on {BackTo}",
                cancelled.MovementNo, undone.ContainerCount, undone.MovementNo);
            return Result<MovementDto>.Success(cancelled with
            {
                SplitUndone = undone with { Message = SplitUndoneMessage(cancelled.MovementNo, undone) },
            });
        }

        if (action != "Complete"
            || read.Value is not { Status: MovementStatus.Completed } movement
            || MovementStages.Normalize(movement.Stage) != MovementStages.Delivery)
        {
            return read;
        }

        // (79) The goods receipt type makes them by hand: no draft, and the answer says what to do instead. (The procedure
        // also stops on its own when the switch is off, should it have been turned between this read and the call.)
        if (!movement.GoodsReceiptsAutomatic)
        {
            _logger.LogInformation("Movement {MovementNo} completed: goods receipts are made by hand (Document Types)", movement.MovementNo);
            return Result<MovementDto>.Success(movement with { GoodsReceipts = [], GoodsReceiptsMessage = ByHandMessage });
        }

        return Result<MovementDto>.Success(await CreateGoodsReceiptsAsync(movement, userId));
    }

    /// <summary>(79) The answer to completing a Delivery when the goods receipt type does not draft them.</summary>
    internal const string ByHandMessage = "Goods receipts are made by hand: use Receive goods… on each container.";

    /* ── the draft goods receipts of a completed Delivery (script 65) ─────────────────────────── */

    /// <summary>
    /// AFTER THE COMMIT, NEVER INSIDE IT: completing a Delivery-stage movement (whatever its type code) creates a draft
    /// goods receipt for each eligible container, but the completion is already committed by usp_Movement_SetStatus and
    /// stays so whatever happens here. Each container has its own transaction in the procedure: one refused container
    /// is its row ('Error', with the database's message), and a failure of the whole call is a warning on the answer.
    /// The movement's own right (containers.movements.manage) is enough: no goods receipt permission is needed for the
    /// drafts, as the person who completes the delivery is rarely the one who receives the goods.
    /// NO CANCELLATION TOKEN: it runs after the commit and on CancellationToken.None (see SetStatusAsync), so only a real
    /// database failure or a command timeout stops it - and either is logged and said on the answer.
    /// </summary>
    private async Task<MovementDto> CreateGoodsReceiptsAsync(MovementDto movement, int userId)
    {
        IReadOnlyList<MovementReceiptResultDto> rows;
        try
        {
            rows = await _movements.CreateGoodsReceiptsAsync(movement.Id, userId, CancellationToken.None);
        }
        catch (OperationCanceledException ex)
        {
            // A guard: nothing here follows the request any more. Never silent if a token is passed in one day.
            _logger.LogWarning(ex, "Movement {MovementNo} completed, but creating its draft goods receipts was cancelled", movement.MovementNo);
            return movement with
            {
                GoodsReceipts = [],
                Warnings =
                [
                    "The movement is completed, but creating its draft goods receipts was interrupted. "
                    + "Use Receive goods… on each container without one.",
                ],
            };
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Movement {MovementNo} completed, but its draft goods receipts were not created", movement.MovementNo);

            // A business refusal says why in plain words; anything else stays in the log, not on the screen.
            var reason = ex is BusinessRuleException rule ? WithoutFinalPeriod(rule.Message) : "the database refused them (see the API log)";
            return movement with
            {
                GoodsReceipts = [],
                Warnings =
                [
                    $"The movement is completed, but its draft goods receipts were not created: {reason}. "
                    + "Use Receive goods… on each container.",
                ],
            };
        }

        var created = rows.Count(r => r.Created);
        _logger.LogInformation("Movement {MovementNo} completed: {Created} draft goods receipt(s) created, {Skipped} container(s) skipped",
            movement.MovementNo, created, rows.Count - created);

        // Read again: the containers' set now shows the drafts (number, status), as the database has them.
        var current = await _movements.GetAsync(movement.Id, CancellationToken.None) ?? movement;
        return current with
        {
            GoodsReceipts = rows,
            // (79) the switch turned off between the read and the call: the procedure made nothing, and says why here
            GoodsReceiptsMessage = rows.Count == 0 && !current.GoodsReceiptsAutomatic ? ByHandMessage : ReceiptsSummary(rows),
            Warnings = rows.Where(r => r.SkipReason == MovementReceiptSkipReasons.Error)
                .Select(r => $"{r.ContainerRef}: the draft goods receipt was not created: {WithoutFinalPeriod(r.Message ?? "refused")}. "
                             + "Use Receive goods… on the container.")
                .ToList(),
        };
    }

    /// <summary>
    /// The notification of rule 5: "Draft goods receipts created: KTG-2026-0031, KTG-2026-0032 (warehouse to choose).
    /// KTG-2026-0032: choose the warehouse (LUB, the container's, has warehouses under it: …). Not created: KTG-2026-0033
    /// already has GRN-BR-002-000004." Null when the movement had no container. A draft made without the container's
    /// own warehouse says why (script 72), once per reason for the containers that share it. Each list names at most
    /// <see cref="SummaryNames"/> containers, then "and N more" (script 78: a Delivery of 8,000 containers wrote 8,000
    /// refs into one message).
    /// </summary>
    internal static string? ReceiptsSummary(IReadOnlyList<MovementReceiptResultDto> rows)
    {
        var created = rows.Where(r => r.Created)
            .Select(r => r.WarehouseCode is null ? $"{r.ContainerRef} (warehouse to choose)" : r.ContainerRef)
            .ToList();
        var whyToChoose = rows
            .Select(r => (r.ContainerRef, Reason: WarehouseToChooseReason(r)))
            .Where(x => x.Reason is not null)
            .GroupBy(x => x.Reason!, StringComparer.Ordinal)
            .Select(g => $"{NameSome(g.Select(x => x.ContainerRef).ToList(), ", ")}: {g.Key}.")
            .ToList();
        var skipped = rows.Where(r => !r.Created).Select(r => $"{r.ContainerRef} {SkipPhrase(r)}").ToList();

        var parts = new List<string>(2 + whyToChoose.Count);
        if (created.Count > 0)
        {
            parts.Add($"{(created.Count == 1 ? "Draft goods receipt created" : "Draft goods receipts created")}: {NameSome(created, ", ")}.");
            parts.AddRange(whyToChoose);
        }

        if (skipped.Count > 0)
        {
            parts.Add($"Not created: {NameSome(skipped, "; ")}.");
        }

        return parts.Count > 0 ? string.Join(' ', parts) : null;
    }

    /// <summary>How many containers a list of the Delivery summary names before "and N more".</summary>
    internal const int SummaryNames = 10;

    /// <summary>"KTG-2026-0001, KTG-2026-0002 and 7,998 more": the first <see cref="SummaryNames"/>, then the count.</summary>
    private static string NameSome(IReadOnlyList<string> names, string separator) =>
        names.Count <= SummaryNames
            ? string.Join(separator, names)
            : $"{string.Join(separator, names.Take(SummaryNames))} and {(names.Count - SummaryNames).ToString("N0", System.Globalization.CultureInfo.InvariantCulture)} more";

    private static string SkipPhrase(MovementReceiptResultDto row) => row.SkipReason switch
    {
        MovementReceiptSkipReasons.Received when row.GoodsReceiptNumber is { } number => $"already has {number}",
        MovementReceiptSkipReasons.Received => "is already offloaded",
        MovementReceiptSkipReasons.HasDraft => "already has a draft goods receipt",
        MovementReceiptSkipReasons.NotConfirmed => "is not confirmed",
        MovementReceiptSkipReasons.Cancelled => "is cancelled",
        MovementReceiptSkipReasons.NoLines => "has no lines",
        _ => $"was refused: {WithoutFinalPeriod(row.Message ?? "unknown reason")}",
    };

    /// <summary>
    /// Why a draft was created without a warehouse although its container has one, from the database's sentence
    /// (usp_GoodsReceipt_CreateForMovement, script 72): "choose the warehouse (LUB, the container's, has warehouses
    /// under it: …)". Null for a draft with a warehouse, for the plain "choose the warehouse" (the container has none)
    /// and for a skipped container.
    /// </summary>
    internal static string? WarehouseToChooseReason(MovementReceiptResultDto row)
    {
        const string prefix = "Draft goods receipt created: ";
        if (!row.Created || row.WarehouseCode is not null || row.Message is not { } message
            || !message.StartsWith(prefix, StringComparison.Ordinal))
        {
            return null;
        }

        var reason = WithoutFinalPeriod(message[prefix.Length..]);
        return reason.Contains('(', StringComparison.Ordinal) ? reason : null;
    }

    private static string WithoutFinalPeriod(string text) => text.Trim().TrimEnd('.');
}
