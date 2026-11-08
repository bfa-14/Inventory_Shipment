using System.Globalization;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using static Inventory_Shipment.Service.Implementations.LogisticsRuleFailures;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// (111) SHIPMENT STAGES: a container moves on by choosing its new stage - "At port Dar es Salaam", "Dar es Salaam →
/// Mokambo", "Offloaded in Lubumbashi" - one container or the forwarder's whole list. The database says what each stage
/// does to each container (usp_ShipmentStage_Preview); this service does it WITH THE MOVEMENT PROCEDURES, never around
/// them, so every rule of the movements holds (one leg at a time, from where it is, no date in the future or before the
/// previous leg):
/// <list type="bullet">
///   <item>a Leg stage: usp_Movement_AddLeg, started at once - one movement for a sea leg, one per container (each truck)
///   for the others;</item>
///   <item>an Arrive stage: the movement's own Complete, or Complete only some containers (the ticked ones get their own
///   movement) when the others did not arrive;</item>
///   <item>an Offload stage: the same completion, one more leg started and completed when the container is not at the
///   place yet, then its goods receipt - the draft a completed Delivery made, else a new one - POSTED for the full
///   quantity loaded.</item>
/// </list>
/// EACH GROUP ON ITS OWN: one refusal never stops the others. A goods receipt that cannot be posted (no warehouse) leaves
/// the container delivered with its draft, said as a warning: the offload happened, the stock waits for the draft.
/// </summary>
public sealed class ShipmentStageService : IShipmentStageService
{
    /// <summary>The containers one apply takes: the forwarder's list of a big order.</summary>
    internal const int MaxContainers = 5000;

    private const string DayFormat = "dd/MM/yyyy";
    private const string DatabaseDidNotAnswer = "the database did not answer (see the API log)";

    private readonly IShipmentStageRepository _stages;
    private readonly IMovementRepository _movementData;
    private readonly IMovementService _movements;
    private readonly IGoodsReceiptService _receipts;
    private readonly ILogger<ShipmentStageService> _logger;

    public ShipmentStageService(
        IShipmentStageRepository stages, IMovementRepository movementData, IMovementService movements,
        IGoodsReceiptService receipts, ILogger<ShipmentStageService> logger)
    {
        _stages = stages;
        _movementData = movementData;
        _movements = movements;
        _receipts = receipts;
        _logger = logger;
    }

    /* ── the stages ───────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<IReadOnlyList<ShipmentStageDto>>> ListAsync(
        bool activeOnly, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.View) && !permissions.Contains(Permissions.MasterData.ShipmentStagesManage))
        {
            return Forbidden<IReadOnlyList<ShipmentStageDto>>(Permissions.Containers.View);
        }

        return Result<IReadOnlyList<ShipmentStageDto>>.Success(await _stages.ListAsync(activeOnly, cancellationToken));
    }

    public async Task<Result<ShipmentStageDto>> SaveAsync(
        int? id, SaveShipmentStageRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.ShipmentStagesManage))
        {
            return Forbidden<ShipmentStageDto>(Permissions.MasterData.ShipmentStagesManage);
        }

        int savedId;
        try
        {
            savedId = await _stages.SaveAsync(id, request, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ShipmentStageDto>(ex, "DUPLICATE");
        }

        _logger.LogInformation("Shipment stage {Id} saved by user {UserId}", savedId, userId);
        var saved = (await _stages.ListAsync(false, cancellationToken)).FirstOrDefault(s => s.Id == savedId);
        return saved is null
            ? Result<ShipmentStageDto>.Failure(ErrorType.NotFound, "Shipment stage not found.", "NOT_FOUND")
            : Result<ShipmentStageDto>.Success(saved);
    }

    public async Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.MasterData.ShipmentStagesManage))
        {
            return Result.Failure(ErrorType.Forbidden,
                $"This action needs the {Permissions.MasterData.ShipmentStagesManage} permission.", "FORBIDDEN");
        }

        try
        {
            await _stages.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Shipment stage {Id} deleted by user {UserId}", id, userId);
        return Result.Success();
    }

    public async Task<Result<ShipmentStageCheckDto>> CheckAsync(IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.View) && !permissions.Contains(Permissions.MasterData.ShipmentStagesManage))
        {
            return Forbidden<ShipmentStageCheckDto>(Permissions.Containers.View);
        }

        return Result<ShipmentStageCheckDto>.Success(await _stages.CheckAsync(cancellationToken));
    }

    /* ── moving containers ────────────────────────────────────────────────────────────────────── */

    public async Task<Result<IReadOnlyList<ShipmentStagePreviewRowDto>>> PreviewAsync(
        ShipmentStagePreviewRequest request, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.MovementsManage))
        {
            return Forbidden<IReadOnlyList<ShipmentStagePreviewRowDto>>(Permissions.Containers.MovementsManage);
        }

        var ids = (request.ContainerIds ?? []).Distinct().ToList();
        if (InvalidIds(ids) is { } invalid)
        {
            return Result<IReadOnlyList<ShipmentStagePreviewRowDto>>.Failure(ErrorType.Validation, invalid, "VALIDATION");
        }

        try
        {
            return Result<IReadOnlyList<ShipmentStagePreviewRowDto>>.Success(await _stages.PreviewAsync(
                request.StageId, ids, permissions.Contains(Permissions.Containers.Confirm), cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<ShipmentStagePreviewRowDto>>(ex);
        }
    }

    public async Task<Result<IReadOnlyList<ShipmentStageMatchRowDto>>> MatchNumbersAsync(
        ShipmentStageMatchRequest request, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.MovementsManage))
        {
            return Forbidden<IReadOnlyList<ShipmentStageMatchRowDto>>(Permissions.Containers.MovementsManage);
        }

        var numbers = request.Numbers ?? [];
        if (numbers.Count == 0 || numbers.Count > MaxContainers)
        {
            return Result<IReadOnlyList<ShipmentStageMatchRowDto>>.Failure(ErrorType.Validation,
                $"Give between 1 and {MaxContainers.ToString("N0", CultureInfo.InvariantCulture)} container numbers.", "VALIDATION");
        }

        return Result<IReadOnlyList<ShipmentStageMatchRowDto>>.Success(await _stages.MatchNumbersAsync(numbers, cancellationToken));
    }

    public async Task<Result<ApplyShipmentStageResultDto>> ApplyAsync(
        ApplyShipmentStageRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.MovementsManage))
        {
            return Forbidden<ApplyShipmentStageResultDto>(Permissions.Containers.MovementsManage);
        }

        var items = request.Items ?? [];
        if (ValidateItems(items) is { } invalid)
        {
            return Result<ApplyShipmentStageResultDto>.Failure(ErrorType.Validation, invalid, "VALIDATION");
        }

        var stages = (await _stages.ListAsync(false, cancellationToken)).ToDictionary(s => s.Id);
        var canConfirm = permissions.Contains(Permissions.Containers.Confirm);
        var canReceive = permissions.Contains(Permissions.Purchase.GoodsReceiptsCreate)
                         && permissions.Contains(Permissions.Purchase.GoodsReceiptsPost);
        var results = new Dictionary<int, ApplyShipmentStageItemResultDto>();

        foreach (var byStage in items.GroupBy(i => i.StageId))
        {
            var list = byStage.ToList();
            if (!stages.TryGetValue(byStage.Key, out var stage))
            {
                foreach (var item in list) results[item.ContainerId] = Refused(item, null, null, "Shipment stage not found.", "NOT_FOUND");
                continue;
            }

            if (stage.Kind == ShipmentStageKinds.Offload && !canReceive)
            {
                foreach (var item in list)
                {
                    results[item.ContainerId] = Refused(item, null, stage,
                        "Offloading posts the goods receipt: it needs Create and Post Goods Receipts.", "FORBIDDEN");
                }
                continue;
            }

            // EACH STAGE ON ITS OWN, whatever fails: a deadlock or a timeout must not lose what the others did.
            try
            {
                await ApplyStageAsync(stage, list, canConfirm, userId, permissions, results, cancellationToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogError(ex, "Update stage: stage {StageId} failed for user {UserId}", stage.Id, userId);
                foreach (var item in list.Where(i => !results.ContainsKey(i.ContainerId)))
                {
                    results[item.ContainerId] = Refused(item, null, stage, $"Not moved: {DatabaseDidNotAnswer}.", "UNEXPECTED");
                }
            }
        }

        var ordered = items.Select(i => results[i.ContainerId]).ToList();
        var moved = ordered.Count(r => r.Ok);
        var skipped = ordered.Count(r => r.Skipped);
        var refused = ordered.Count - moved - skipped;
        _logger.LogInformation("Update stage by user {UserId}: {Moved} moved, {Skipped} already there, {Refused} refused",
            userId, moved, skipped, refused);

        return Result<ApplyShipmentStageResultDto>.Success(new ApplyShipmentStageResultDto
        {
            Items = ordered,
            Moved = moved,
            Skipped = skipped,
            Refused = refused,
            Message = Summary(moved, skipped, refused),
        });
    }

    /// <summary>One stage: the preview says what each container does now, then each action runs in its groups.</summary>
    private async Task ApplyStageAsync(
        ShipmentStageDto stage, IReadOnlyList<ApplyShipmentStageItem> items, bool canConfirm, int userId,
        IReadOnlySet<string> permissions, Dictionary<int, ApplyShipmentStageItemResultDto> results,
        CancellationToken cancellationToken)
    {
        IReadOnlyList<ShipmentStagePreviewRowDto> preview;
        try
        {
            preview = await _stages.PreviewAsync(stage.Id, items.Select(i => i.ContainerId).ToList(), canConfirm, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            foreach (var item in items) results[item.ContainerId] = Refused(item, null, stage, ex.Message, Describe(ex).Code);
            return;
        }

        var rows = preview.ToDictionary(r => r.ContainerId);
        var ready = new List<(ApplyShipmentStageItem Item, ShipmentStagePreviewRowDto Row)>();
        foreach (var item in items)
        {
            var row = rows.GetValueOrDefault(item.ContainerId);
            if (row is null || !row.Found)
            {
                results[item.ContainerId] = Refused(item, row, stage, "Container not found.", "NOT_FOUND");
            }
            else if (row.AlreadyThere)
            {
                results[item.ContainerId] = new ApplyShipmentStageItemResultDto
                {
                    ContainerId = item.ContainerId,
                    ContainerRef = row.ContainerRef,
                    StageName = stage.StageName,
                    Skipped = true,
                    Message = $"{row.ContainerRef}: already at {stage.StageName}.",
                };
            }
            else if (!row.CanMove)
            {
                results[item.ContainerId] = Refused(item, row, stage, WithName(row.ContainerRef, row.Reason ?? "it cannot move to this stage"), "CANNOT_MOVE");
            }
            else
            {
                ready.Add((item, row));
            }
        }

        var movements = new Dictionary<int, List<string>>();
        var moved = new List<(ApplyShipmentStageItem Item, ShipmentStagePreviewRowDto Row)>();

        // 1. The legs started (a Leg stage).
        foreach (var group in ready.Where(r => r.Row.Action == ShipmentStageActions.StartLeg)
                     .GroupBy(r => (r.Item.Date, r.Row.PlaceId, Sea: IsSea(stage) ? r.Item.VehicleOrVessel : null, Eta: IsSea(stage) ? r.Item.Eta : null)))
        {
            var done = await StartLegAsync(stage, group.ToList(), stage.FromPlaceId ?? group.Key.PlaceId, complete: false,
                canConfirm, userId, permissions, movements, results, cancellationToken);
            moved.AddRange(done);
        }

        // 2. The legs completed (an Arrive stage, an Offload stage reached by the leg): whole, or only the ticked ones.
        var completing = ready.Where(r => r.Row.Action is ShipmentStageActions.Complete or ShipmentStageActions.CompleteThenDeliver).ToList();
        var thenDeliver = new List<(ApplyShipmentStageItem Item, ShipmentStagePreviewRowDto Row)>();
        foreach (var group in completing.GroupBy(r => (r.Row.MovementId, r.Item.Date)))
        {
            var done = await CompleteAsync(stage, group.ToList(), userId, permissions, movements, results, cancellationToken);
            moved.AddRange(done.Where(d => d.Row.Action == ShipmentStageActions.Complete));
            thenDeliver.AddRange(done.Where(d => d.Row.Action == ShipmentStageActions.CompleteThenDeliver));
        }

        // 3. The last leg of an Offload stage, started and completed: after the completion above (from the place it
        //    reached), or from where the container already stood.
        foreach (var group in thenDeliver.GroupBy(r => (r.Item.Date, r.Row.MovementId)))
        {
            var done = await StartLegAsync(stage, group.ToList(), fromPlaceId: null, complete: true,
                canConfirm, userId, permissions, movements, results, cancellationToken);
            moved.AddRange(done);
        }

        foreach (var group in ready.Where(r => r.Row.Action == ShipmentStageActions.Deliver).GroupBy(r => (r.Item.Date, r.Row.PlaceId)))
        {
            var done = await StartLegAsync(stage, group.ToList(), group.Key.PlaceId, complete: true,
                canConfirm, userId, permissions, movements, results, cancellationToken);
            moved.AddRange(done);
        }

        moved.AddRange(ready.Where(r => r.Row.Action == ShipmentStageActions.Receive));

        // 4. The goods receipts of an Offload stage, posted for the full quantity.
        var receipts = new Dictionary<int, (int? Id, string? Number, string? Warning)>();
        if (stage.Kind == ShipmentStageKinds.Offload && moved.Count > 0)
        {
            receipts = await ReceiveAsync(moved, userId, permissions, cancellationToken);
        }

        foreach (var (item, row) in moved)
        {
            var made = movements.GetValueOrDefault(item.ContainerId) ?? [];
            var receipt = receipts.GetValueOrDefault(item.ContainerId);
            var onlyReceipt = row.Action == ShipmentStageActions.Receive;

            // Only a goods receipt to post, and it was refused: nothing happened, so it is no move.
            if (onlyReceipt && receipt.Number is null)
            {
                results[item.ContainerId] = Refused(item, row, stage,
                    WithName(row.ContainerRef, receipt.Warning ?? "its goods receipt was not posted"), "RECEIPT_NOT_POSTED");
                continue;
            }

            var text = $"{row.ContainerRef}: {stage.StageName} on {Day(item.Date)}"
                       + (made.Count > 0 ? $" ({string.Join(", ", made)})." : ".")
                       + (receipt.Number is not null ? $" Goods receipt {receipt.Number} posted." : string.Empty);
            results[item.ContainerId] = new ApplyShipmentStageItemResultDto
            {
                ContainerId = item.ContainerId,
                ContainerRef = row.ContainerRef,
                StageName = stage.StageName,
                Ok = true,
                Message = text,
                Movements = made,
                GoodsReceiptId = receipt.Id,
                GoodsReceiptNumber = receipt.Number,
                Warning = receipt.Warning,
            };
        }
    }

    /// <summary>
    /// A new leg for a group of containers standing at one place, started on the date: one movement for a sea leg, one per
    /// container (with its truck no. and ETA) for the others. complete: also completed on the same date (the last leg of
    /// an Offload stage - a Delivery drafts its goods receipts). The containers it moved; the others are refused.
    /// </summary>
    private async Task<List<(ApplyShipmentStageItem Item, ShipmentStagePreviewRowDto Row)>> StartLegAsync(
        ShipmentStageDto stage, IReadOnlyList<(ApplyShipmentStageItem Item, ShipmentStagePreviewRowDto Row)> group,
        int? fromPlaceId, bool complete, bool canConfirm, int userId, IReadOnlySet<string> permissions,
        Dictionary<int, List<string>> movements, Dictionary<int, ApplyShipmentStageItemResultDto> results,
        CancellationToken cancellationToken)
    {
        var moved = new List<(ApplyShipmentStageItem Item, ShipmentStagePreviewRowDto Row)>();
        var onePerContainer = !IsSea(stage);
        var first = group[0].Item;
        var command = new AddLegCommand
        {
            ContainerIds = group.Select(g => g.Item.ContainerId).ToList(),
            MovementTypeId = stage.MovementTypeId,
            FromPlaceId = fromPlaceId,
            ToPlaceId = stage.ToPlaceId,
            StartDate = first.Date,
            Eta = onePerContainer || complete ? null : first.Eta,
            VehicleOrVessel = onePerContainer ? null : Clean(first.VehicleOrVessel),
            StartNow = true,
            UpdateContainers = true,
            OnePerContainer = onePerContainer,
            PerContainer = onePerContainer
                ? group.Where(g => Clean(g.Item.VehicleOrVessel) is not null || (g.Item.Eta is not null && !complete))
                       .Select(g => new NextStepLegContainerRequest
                       {
                           ContainerId = g.Item.ContainerId,
                           VehicleOrVessel = Clean(g.Item.VehicleOrVessel),
                           Eta = complete ? null : g.Item.Eta,
                       }).ToList()
                : [],
        };

        IReadOnlyList<AddedLegDto> made;
        try
        {
            made = await _movementData.AddLegAsync(command, canConfirm, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            foreach (var (item, row) in group)
            {
                results[item.ContainerId] = Refused(item, row, stage, PrefixIfAfter(item, movements, failure.Message), failure.Code);
            }
            return moved;
        }

        foreach (var leg in made)
        {
            var members = leg.ContainerId is { } one ? group.Where(g => g.Item.ContainerId == one).ToList() : group.ToList();
            if (complete)
            {
                var completed = await _movements.CompleteAsync(
                    leg.Id, new MovementStatusRequest { Date = first.Date }, userId, permissions, cancellationToken);
                if (completed.IsFailure)
                {
                    foreach (var (item, row) in members)
                    {
                        results[item.ContainerId] = Refused(item, row, stage,
                            $"{row.ContainerRef}: {leg.MovementNo} was started but not completed: {WithoutFinalPeriod(completed.Error)}. Complete it on its page.",
                            completed.Code);
                    }
                    continue;
                }
            }

            foreach (var member in members)
            {
                Remember(movements, member.Item.ContainerId, leg.MovementNo);
                moved.Add(member);
            }
        }

        _logger.LogInformation("Update stage {Stage}: {Count} movement(s) {Action} for {Containers} container(s) by user {UserId}",
            stage.StageName, made.Count, complete ? "started and completed" : "started", group.Count, userId);
        return moved;
    }

    /// <summary>
    /// The containers' leg completed on the date: the movement's own Complete when they are all of its containers, else
    /// Complete only some (they get their own movement, completed; the others travel on). The containers it moved.
    /// </summary>
    private async Task<List<(ApplyShipmentStageItem Item, ShipmentStagePreviewRowDto Row)>> CompleteAsync(
        ShipmentStageDto stage, IReadOnlyList<(ApplyShipmentStageItem Item, ShipmentStagePreviewRowDto Row)> group,
        int userId, IReadOnlySet<string> permissions, Dictionary<int, List<string>> movements,
        Dictionary<int, ApplyShipmentStageItemResultDto> results, CancellationToken cancellationToken)
    {
        var movementId = group[0].Row.MovementId!.Value;
        var date = group[0].Item.Date;
        var ids = group.Select(g => g.Item.ContainerId).ToList();
        string? movementNo;
        string? error;
        string? code;

        if (ids.Count >= group[0].Row.MovementContainerCount)
        {
            var completed = await _movements.CompleteAsync(movementId, new MovementStatusRequest { Date = date }, userId, permissions, cancellationToken);
            movementNo = completed.Value?.MovementNo;
            error = completed.IsFailure ? completed.Error : null;
            code = completed.Code;
        }
        else
        {
            var split = await _movements.CompleteSomeAsync(
                movementId, new CompleteSomeContainersRequest { ContainerIds = ids, Date = date }, userId, permissions, cancellationToken);
            movementNo = split.Value?.MovementNo;
            error = split.IsFailure ? split.Error : split.Value is { Ok: false } notCompleted ? notCompleted.Message : null;
            code = split.IsFailure ? split.Code : split.Value?.Code;
        }

        if (error is not null)
        {
            foreach (var (item, row) in group)
            {
                results[item.ContainerId] = Refused(item, row, stage, WithName(row.ContainerRef, error), code);
            }
            return [];
        }

        foreach (var (item, _) in group)
        {
            Remember(movements, item.ContainerId, movementNo ?? group[0].Row.MovementNo ?? string.Empty);
        }
        return group.ToList();
    }

    /// <summary>
    /// The goods receipt of each offloaded container, posted: the draft a completed Delivery made, else a new one for the
    /// full quantity loaded, dated the stage's date. A refusal is a warning - the container is delivered, its draft kept.
    /// </summary>
    private async Task<Dictionary<int, (int? Id, string? Number, string? Warning)>> ReceiveAsync(
        IReadOnlyList<(ApplyShipmentStageItem Item, ShipmentStagePreviewRowDto Row)> containers, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken)
    {
        var outcome = new Dictionary<int, (int? Id, string? Number, string? Warning)>();
        var drafts = await _stages.DraftReceiptsAsync(containers.Select(c => c.Item.ContainerId).ToList(), cancellationToken);

        foreach (var (item, _) in containers)
        {
            try
            {
                if (drafts.TryGetValue(item.ContainerId, out var draftId))
                {
                    var posted = await _receipts.PostAsync(draftId, null, userId, permissions, cancellationToken);
                    outcome[item.ContainerId] = posted.IsSuccess
                        ? (draftId, posted.Value?.DocumentNumber, null)
                        : (draftId, null, $"Its draft goods receipt was not posted: {WithoutFinalPeriod(posted.Error)}. Open it to finish.");
                    continue;
                }

                var created = await _receipts.ReceiveContainerAsync(
                    new ReceiveContainerRequest { ContainerId = item.ContainerId, DocumentDate = item.Date, Post = true },
                    userId, permissions, cancellationToken);
                outcome[item.ContainerId] = created switch
                {
                    { IsSuccess: true, Value: { Posted: true } r } => (r.Id, r.DocumentNumber, null),
                    { IsSuccess: true, Value: { } r } => (r.Id, null,
                        $"Its draft goods receipt was not posted: {WithoutFinalPeriod(r.PostRefusal?.Message ?? r.Message)}. Open it to finish."),
                    _ => (null, null, $"Its goods receipt was not made: {WithoutFinalPeriod(created.Error)}."),
                };
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogError(ex, "Update stage: the goods receipt of container {ContainerId} failed", item.ContainerId);
                outcome[item.ContainerId] = (null, null, $"Its goods receipt was not posted: {DatabaseDidNotAnswer}.");
            }
        }

        return outcome;
    }

    /* ── the checks and the words ─────────────────────────────────────────────────────────────── */

    private static string? InvalidIds(IReadOnlyCollection<int> ids)
    {
        if (ids.Count == 0) return "Tick at least one container.";
        if (ids.Any(id => id <= 0)) return "A container id must be greater than zero.";
        return ids.Count > MaxContainers
            ? $"At most {MaxContainers.ToString("N0", CultureInfo.InvariantCulture)} containers at a time."
            : null;
    }

    private static string? ValidateItems(IReadOnlyList<ApplyShipmentStageItem> items)
    {
        if (InvalidIds(items.Select(i => i.ContainerId).ToList()) is { } invalid) return invalid;
        if (items.Any(i => i.StageId <= 0)) return "Choose the stage of every container.";
        if (items.Any(i => i.Date is null)) return "Give the date of every container.";
        var twice = items.GroupBy(i => i.ContainerId).FirstOrDefault(g => g.Count() > 1);
        return twice is not null ? $"Container {twice.Key} is given twice: a container moves to one stage at a time." : null;
    }

    private static bool IsSea(ShipmentStageDto stage)
        => string.Equals(MovementStages.Normalize(stage.MovementTypeStage), MovementStages.Sea, StringComparison.Ordinal);

    private static ApplyShipmentStageItemResultDto Refused(
        ApplyShipmentStageItem item, ShipmentStagePreviewRowDto? row, ShipmentStageDto? stage, string message, string? code) => new()
    {
        ContainerId = item.ContainerId,
        ContainerRef = row?.ContainerRef,
        StageName = stage?.StageName,
        Message = message,
        Code = code,
    };

    private static void Remember(Dictionary<int, List<string>> movements, int containerId, string movementNo)
    {
        if (string.IsNullOrEmpty(movementNo)) return;
        if (!movements.TryGetValue(containerId, out var list)) movements[containerId] = list = [];
        if (!list.Contains(movementNo)) list.Add(movementNo);
    }

    /// <summary>The last leg refused after its arrival was recorded: say both, so the reader knows where it stands.</summary>
    private static string PrefixIfAfter(ApplyShipmentStageItem item, Dictionary<int, List<string>> movements, string message)
        => movements.TryGetValue(item.ContainerId, out var done) && done.Count > 0
            ? $"Arrival recorded ({string.Join(", ", done)}); the last leg was not made: {message}"
            : message;

    private static string Summary(int moved, int skipped, int refused)
    {
        var parts = new List<string> { $"{moved.ToString("N0", CultureInfo.InvariantCulture)} container{(moved == 1 ? "" : "s")} moved" };
        if (skipped > 0) parts.Add($"{skipped.ToString("N0", CultureInfo.InvariantCulture)} already there");
        if (refused > 0) parts.Add($"{refused.ToString("N0", CultureInfo.InvariantCulture)} refused");
        return string.Join(", ", parts) + ".";
    }

    private static string Day(DateOnly? date) => date?.ToString(DayFormat, CultureInfo.InvariantCulture) ?? "today";

    private static string? Clean(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private static string WithoutFinalPeriod(string? text) => (text ?? string.Empty).Trim().TrimEnd('.');

    private static string WithName(string? name, string reason)
    {
        var text = reason.Trim();
        text = text.EndsWith('.') || text.EndsWith(')') ? text : text + ".";
        return string.IsNullOrEmpty(name) || text.Contains(name, StringComparison.Ordinal) ? text : $"{name}: {text}";
    }
}
