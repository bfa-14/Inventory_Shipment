using System.Globalization;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Microsoft.Extensions.Logging;
using static Inventory_Shipment.Service.Implementations.LogisticsRuleFailures;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// (81) THE NEXT STEP OF A CONTAINER, for one container or 300 (shipment phase 2). The database says what each
/// container's step is and groups them (usp_Container_NextStepPreview); applying a group never goes around a movement:
/// <list type="bullet">
///   <item>Complete and Start go through <see cref="SetStatusAsync"/>, the movement's own Complete / Start, the only
///   place that drafts the goods receipts of a completed Delivery after the commit (script 79's switch included);</item>
///   <item>a new leg goes through usp_Movement_AddLeg, which saves and starts it with the movement procedures, so every
///   phase 1 rule holds (one movement at a time, the place rules, no date in the future or before the previous leg).</item>
/// </list>
/// EACH GROUP ON ITS OWN: one refusal never stops the others, and each is all or nothing inside. The "Then" leg after a
/// Complete is a SECOND step once the completion is committed: refused, it is a warning and the arrival stays.
/// </summary>
public sealed partial class MovementService
{
    /// <summary>The containers one preview or one apply takes: a selection of every container of a big order.</summary>
    internal const int MaxNextStepContainers = 5000;

    /// <summary>The groups one apply takes (the preview of 1,201 containers gave 51).</summary>
    internal const int MaxNextStepGroups = 200;

    /// <summary>The date of the messages, as the database writes it in its own ("reached Dar es Salaam on 12/10/2026").</summary>
    private const string DayFormat = "dd/MM/yyyy";

    /// <summary>The BlockGroup of a draft for a reader without containers.confirm (usp_Container_NextStepPreview).</summary>
    private const string DraftNotConfirmableGroup = "Draft - you may not confirm containers";

    private const string ContainerNotFoundMessage = "Container not found.";

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<ContainerNextStepDto>> GetNextStepAsync(
        int containerId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        // Read-only, as the container page itself: what the button says. Applying it needs containers.movements.manage.
        if (!permissions.Contains(Permissions.Containers.View))
        {
            return Forbidden<ContainerNextStepDto>(Permissions.Containers.View);
        }

        if (containerId <= 0)
        {
            return Result<ContainerNextStepDto>.Failure(ErrorType.Validation, "A container id must be greater than zero.", "VALIDATION");
        }

        NextStepPreviewDto preview;
        try
        {
            preview = await _movements.NextStepPreviewAsync(
                [containerId], permissions.Contains(Permissions.Containers.Confirm), cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ContainerNextStepDto>(ex);
        }

        return preview.Containers.FirstOrDefault() is { Found: true } row
            ? Result<ContainerNextStepDto>.Success(row)
            : Result<ContainerNextStepDto>.Failure(ErrorType.NotFound, ContainerNotFoundMessage, "NOT_FOUND");
    }

    public async Task<Result<NextStepPreviewDto>> PreviewNextStepAsync(
        NextStepPreviewRequest request, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.MovementsManage))
        {
            return Forbidden<NextStepPreviewDto>(Permissions.Containers.MovementsManage);
        }

        var ids = request.ContainerIds ?? [];
        if (InvalidContainerIds(ids) is { } invalid)
        {
            return Result<NextStepPreviewDto>.Failure(ErrorType.Validation, invalid, "VALIDATION");
        }

        try
        {
            // Without containers.confirm a draft that never moved goes under "Cannot move on": the new leg would refuse it.
            return Result<NextStepPreviewDto>.Success(await _movements.NextStepPreviewAsync(
                ids, permissions.Contains(Permissions.Containers.Confirm), cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<NextStepPreviewDto>(ex);
        }
    }

    /* ── applying ─────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<IReadOnlyList<NextStepGroupResultDto>>> ApplyNextStepAsync(
        ApplyNextStepRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.MovementsManage))
        {
            return Forbidden<IReadOnlyList<NextStepGroupResultDto>>(Permissions.Containers.MovementsManage);
        }

        var groups = request.Groups ?? [];
        var (kinds, invalid) = ValidateGroups(groups);
        if (invalid is not null)
        {
            return Result<IReadOnlyList<NextStepGroupResultDto>>.Failure(ErrorType.Validation, invalid, "VALIDATION");
        }

        var canConfirm = permissions.Contains(Permissions.Containers.Confirm);

        // WHAT EACH CONTAINER'S STEP IS NOW, in one set-based call: the dialog may have stood open while someone else
        // completed the movement or started the leg, and a step taken on a stale preview would surprise its reader.
        NextStepPreviewDto now;
        try
        {
            now = await _movements.NextStepPreviewAsync(groups.SelectMany(g => g.ContainerIds), canConfirm, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<NextStepGroupResultDto>>(ex);
        }

        var rows = now.Containers.ToDictionary(r => r.ContainerId);
        var results = new List<NextStepGroupResultDto>(groups.Count);
        for (var i = 0; i < groups.Count; i++)
        {
            results.Add(await ApplyGroupAsync(groups[i], kinds[i], rows, canConfirm, userId, permissions, cancellationToken));
        }

        _logger.LogInformation("Next step by user {UserId}: {Applied} of {Groups} group(s) applied, {Containers} container(s)",
            userId, results.Count(r => r.Ok), results.Count, rows.Count);
        return Result<IReadOnlyList<NextStepGroupResultDto>>.Success(results);
    }

    private async Task<NextStepGroupResultDto> ApplyGroupAsync(
        NextStepGroupRequest group, string kind, IReadOnlyDictionary<int, ContainerNextStepDto> now, bool canConfirm,
        int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken)
    {
        var ids = group.ContainerIds.Distinct().ToList();
        var rows = ids.Select(id => now.GetValueOrDefault(id)).ToList();

        if (StepRefusal(group, kind, ids, rows, canConfirm) is { } refusal)
        {
            return Refused(group, kind, ids, refusal.Message, refusal.Code);
        }

        var found = rows.Select(r => r!).ToList();
        return kind switch
        {
            ContainerNextStepKinds.Complete => await CompleteGroupAsync(group, ids, found, canConfirm, userId, permissions, cancellationToken),
            ContainerNextStepKinds.StartPlanned => await StartGroupAsync(group, ids, found, userId, permissions, cancellationToken),
            _ => await NewLegGroupAsync(group, kind, ids, found, canConfirm, userId, cancellationToken),
        };
    }

    /// <summary>
    /// A movement in progress: its own Complete (a Delivery drafts its goods receipts after the commit), then the "Then"
    /// leg as a second step. The completion moves every container of the movement, ticked or not (no split in phase 2).
    /// </summary>
    private async Task<NextStepGroupResultDto> CompleteGroupAsync(
        NextStepGroupRequest group, IReadOnlyList<int> ids, IReadOnlyList<ContainerNextStepDto> rows, bool canConfirm,
        int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken)
    {
        var completed = await SetStatusAsync(
            group.MovementId!.Value, "Complete", new MovementStatusRequest { Date = group.Date, RowVersion = group.RowVersion },
            userId, permissions, cancellationToken);
        if (completed.IsFailure || completed.Value is not { } movement)
        {
            return Refused(group, ContainerNextStepKinds.Complete, ids, completed.Error ?? "The movement was not completed.", completed.Code);
        }

        var warnings = new List<string>(movement.Warnings);
        var thenMovements = new List<NextStepMovementDto>();
        var message = CompletionMessage(movement, rows);
        var stage = MovementStages.Normalize(movement.Stage);

        // THE "THEN" LEG, once the completion is committed: never after a Delivery (its goods are received next).
        if (group.Then is { } then && stage != MovementStages.Delivery)
        {
            var (made, said, thenWarnings) = await ThenLegAsync(group, then, ids, movement, canConfirm, userId, cancellationToken);
            thenMovements.AddRange(made);
            warnings.AddRange(thenWarnings);
            message = string.Join(' ', said.Prepend(message));
        }

        return new NextStepGroupResultDto
        {
            Key = group.Key,
            Kind = ContainerNextStepKinds.Complete,
            Ok = true,
            Message = message,
            ContainerIds = ids,
            Movements = [new NextStepMovementDto { Id = movement.Id, MovementNo = movement.MovementNo, Status = movement.Status }],
            ThenMovements = thenMovements,
            GoodsReceipts = movement.GoodsReceipts,
            GoodsReceiptsMessage = movement.GoodsReceiptsMessage,
            Warnings = warnings,
        };
    }

    /// <summary>A planned movement: its own Start, with every rule of phase 1 (70012, 70015, 70016, 70018, no future date).</summary>
    private async Task<NextStepGroupResultDto> StartGroupAsync(
        NextStepGroupRequest group, IReadOnlyList<int> ids, IReadOnlyList<ContainerNextStepDto> rows, int userId,
        IReadOnlySet<string> permissions, CancellationToken cancellationToken)
    {
        var started = await SetStatusAsync(
            group.MovementId!.Value, "Start", new MovementStatusRequest { Date = group.Date, RowVersion = group.RowVersion },
            userId, permissions, cancellationToken);
        if (started.IsFailure || started.Value is not { } movement)
        {
            return Refused(group, ContainerNextStepKinds.StartPlanned, ids, started.Error ?? "The movement was not started.", started.Code);
        }

        var who = Who(movement.Containers.Count, movement.Containers.FirstOrDefault()?.ContainerRef ?? rows[0].ContainerRef);
        return new NextStepGroupResultDto
        {
            Key = group.Key,
            Kind = ContainerNextStepKinds.StartPlanned,
            Ok = true,
            Message = $"{who}: {movement.TypeName} {Route(movement)} started on {MessageDay(movement.StartDate)} ({movement.MovementNo}).{NowStatus(movement)}",
            ContainerIds = ids,
            Movements = [new NextStepMovementDto { Id = movement.Id, MovementNo = movement.MovementNo, Status = movement.Status }],
            Warnings = movement.Warnings,
        };
    }

    /// <summary>
    /// A new leg from where the containers are (Ship, NextLeg): the type and To of the preview unless the request changes
    /// them, one movement for the group or one per container, started or planned - all or nothing.
    /// </summary>
    private async Task<NextStepGroupResultDto> NewLegGroupAsync(
        NextStepGroupRequest group, string kind, IReadOnlyList<int> ids, IReadOnlyList<ContainerNextStepDto> rows,
        bool canConfirm, int userId, CancellationToken cancellationToken)
    {
        // The proposal of the preview, when every container of the group has the same one (the preview groups them so).
        var proposed = SameProposal(rows);
        var typeId = group.MovementTypeId ?? proposed?.TypeId;
        var toPlaceId = group.ToPlaceId
                        ?? (proposed is not null && (group.MovementTypeId is null || group.MovementTypeId == proposed.Value.TypeId)
                            ? proposed.Value.ToPlaceId
                            : null);

        var command = new AddLegCommand
        {
            ContainerIds = ids,
            MovementTypeId = typeId,
            FromPlaceId = group.FromPlaceId,
            ToPlaceId = toPlaceId,
            StartDate = group.Date,
            Eta = group.Eta,
            CarrierPartyId = group.CarrierPartyId,
            VehicleOrVessel = group.VehicleOrVessel,
            VoyageNo = group.VoyageNo,
            Reference = group.Reference,
            BlNo = group.BlNo,
            BlDate = group.BlDate,
            Notes = group.Notes,
            StartNow = group.StartNow,
            UpdateContainers = group.CopyToContainers,
            OnePerContainer = group.OnePerContainer,
            PerContainer = group.PerContainer ?? [],
        };

        IReadOnlyList<AddedLegDto> made;
        try
        {
            made = await _movements.AddLegAsync(command, canConfirm, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Refused(group, kind, ids, failure.Message, failure.Code);
        }

        _logger.LogInformation("Next step: {Count} movement(s) {Action} for {Containers} container(s) by user {UserId}",
            made.Count, group.StartNow ? "started" : "planned", ids.Count, userId);

        return new NextStepGroupResultDto
        {
            Key = group.Key,
            Kind = kind,
            Ok = true,
            Message = await NewLegMessageAsync(made, ids.Count, rows[0].ContainerRef, group.StartNow, cancellationToken),
            ContainerIds = ids,
            Movements = made.Select(ToMovementRef).ToList(),
        };
    }

    /// <summary>
    /// "Then start Customs clearance at Kasumbalesa on the same day": the leg the containers get once arrived, worked out
    /// again now (they are at the movement's To), one AddLeg per group of the new preview. Never a rollback: the
    /// completion is committed, and a refusal is said as "Arrival recorded; Customs clearance was not started: {reason}.
    /// Use Next step…".
    /// </summary>
    private async Task<(IReadOnlyList<NextStepMovementDto> Made, IReadOnlyList<string> Said, IReadOnlyList<string> Warnings)> ThenLegAsync(
        NextStepGroupRequest group, NextStepThenRequest then, IReadOnlyList<int> ids, MovementDto completed, bool canConfirm,
        int userId, CancellationToken cancellationToken)
    {
        var noun = RecordedNoun(completed.Stage);
        var verb = then.StartNow ? "started" : "planned";
        var made = new List<NextStepMovementDto>();
        var said = new List<string>();
        var warnings = new List<string>();

        NextStepPreviewDto after;
        try
        {
            after = await _movements.NextStepPreviewAsync(ids, canConfirm, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            warnings.Add($"{noun} recorded; the next leg was not {verb}: {WithoutFinalPeriod(ex.Message)}. Use Next step…");
            return (made, said, warnings);
        }

        var ready = after.Containers.Where(r => r is { Kind: ContainerNextStepKinds.NextLeg, CanMove: true }).ToList();
        if (ready.Count == 0)
        {
            var why = after.Containers.Select(r => r.BlockedReason ?? r.BlockGroup).FirstOrDefault(r => r is not null)
                      ?? "nothing to propose from here";
            warnings.Add($"{noun} recorded; the next leg was not {verb}: {WithoutFinalPeriod(why)}. Use Next step…");
            return (made, said, warnings);
        }

        foreach (var legGroup in ready.GroupBy(r => r.GroupKey ?? string.Empty, StringComparer.Ordinal))
        {
            var first = legGroup.First();
            var typeId = then.MovementTypeId ?? first.ProposedTypeId;
            var sameType = then.MovementTypeId is null || then.MovementTypeId == first.ProposedTypeId;
            var legName = sameType ? first.ProposedTypeName ?? "The next leg" : "The next leg";
            var toPlaceId = then.ToPlaceId ?? (sameType ? first.ProposedToPlaceId : null);

            // A leg that moves needs its To; a stay takes the place (the procedure does it).
            if (toPlaceId is null && !(sameType && first.ProposedIsStay == true))
            {
                warnings.Add($"{noun} recorded; {legName} was not {verb}: choose the To. Use Next step…");
                continue;
            }

            try
            {
                var legs = await _movements.AddLegAsync(
                    new AddLegCommand
                    {
                        ContainerIds = legGroup.Select(r => r.ContainerId).ToList(),
                        MovementTypeId = typeId,
                        FromPlaceId = first.ProposedFromPlaceId,
                        ToPlaceId = toPlaceId,
                        StartDate = then.Date ?? DateOnly.FromDateTime(completed.EndDate ?? DateTime.UtcNow),
                        StartNow = then.StartNow,
                        UpdateContainers = true,
                        OnePerContainer = then.OnePerContainer ?? first.ProposedOnePerContainer ?? false,
                    },
                    confirmDrafts: false,   // they travelled: no draft left among them
                    userId, cancellationToken);
                made.AddRange(legs.Select(ToMovementRef));
                if (legs.Count > 0)
                {
                    var (phrase, _) = await LegPhraseAsync(legs, then.StartNow, cancellationToken);
                    said.Add($"Then {phrase}.");
                }
            }
            catch (BusinessRuleException ex)
            {
                _logger.LogInformation("Movement {MovementNo} completed; its Then leg was refused: {Reason}", completed.MovementNo, ex.Message);
                warnings.Add($"{noun} recorded; {legName} was not {verb}: {WithoutFinalPeriod(ex.Message)}. Use Next step…");
            }
        }

        return (made, said, warnings);
    }

    /* ── the checks ───────────────────────────────────────────────────────────────────────────── */

    private static string? InvalidContainerIds(IReadOnlyCollection<int> ids)
    {
        if (ids.Count == 0)
        {
            return "Tick at least one container.";
        }

        if (ids.Any(id => id <= 0))
        {
            return "A container id must be greater than zero.";
        }

        return ids.Distinct().Count() > MaxNextStepContainers
            ? $"At most {MaxNextStepContainers.ToString("N0", CultureInfo.InvariantCulture)} containers at a time: tick fewer, or filter the list."
            : null;
    }

    /// <summary>The kind of each group (normalized), or the first problem of the request, said by step number.</summary>
    private static (IReadOnlyList<string> Kinds, string? Invalid) ValidateGroups(IReadOnlyList<NextStepGroupRequest> groups)
    {
        if (groups.Count == 0)
        {
            return ([], "Choose at least one step.");
        }

        if (groups.Count > MaxNextStepGroups)
        {
            return ([], $"At most {MaxNextStepGroups} steps at a time.");
        }

        var kinds = new List<string>(groups.Count);
        var seen = new HashSet<int>();
        for (var i = 0; i < groups.Count; i++)
        {
            var group = groups[i];
            var step = $"Step {i + 1}";
            if (group is null)
            {
                return ([], $"{step} is empty.");
            }

            var kind = ContainerNextStepKinds.Normalize(group.Kind, ContainerNextStepKinds.Applicable);
            if (kind is null)
            {
                return ([], ContainerNextStepKinds.Normalize(group.Kind, [ContainerNextStepKinds.Receive, ContainerNextStepKinds.OpenReceipt]) is not null
                    ? $"{step}: goods are received with Receive goods…, not with a movement."
                    : $"{step}: kind must be Complete, StartPlanned, Ship or NextLeg.");
            }

            var ids = group.ContainerIds ?? [];
            if (ids.Count == 0)
            {
                return ([], $"{step}: tick at least one container.");
            }

            if (ids.Any(id => id <= 0))
            {
                return ([], $"{step}: a container id must be greater than zero.");
            }

            if (kind is ContainerNextStepKinds.Complete or ContainerNextStepKinds.StartPlanned && group.MovementId is null or <= 0)
            {
                return ([], $"{step}: say which movement to {(kind == ContainerNextStepKinds.Complete ? "complete" : "start")} (movementId).");
            }

            // A container takes one step at a time: in two groups, the second would run on what the first just changed.
            foreach (var id in ids.Distinct())
            {
                if (!seen.Add(id))
                {
                    return ([], $"Container {id} is in two steps: a container takes one step at a time.");
                }
            }

            if (group.PerContainer?.FirstOrDefault(p => !ids.Contains(p.ContainerId)) is { } stray)
            {
                return ([], $"{step}: container {stray.ContainerId} has a truck no. or ETA but is not in this step.");
            }

            kinds.Add(kind);
        }

        return seen.Count > MaxNextStepContainers
            ? ([], $"At most {MaxNextStepContainers.ToString("N0", CultureInfo.InvariantCulture)} containers at a time: apply the steps in parts.")
            : (kinds, null);
    }

    /// <summary>
    /// The step asked for is still each container's step now, and it can be taken: else the refusal, naming the container.
    /// A draft without containers.confirm is left to the new leg's procedure: it may wait on a PLANNED leg, only a start
    /// needs it confirmed.
    /// </summary>
    private static (string Message, string Code)? StepRefusal(
        NextStepGroupRequest group, string kind, IReadOnlyList<int> ids, IReadOnlyList<ContainerNextStepDto?> rows,
        bool canConfirm)
    {
        for (var i = 0; i < rows.Count; i++)
        {
            if (rows[i] is not { Found: true } row)
            {
                return ($"Container {ids[i]} not found.", "NOT_FOUND");
            }

            var name = row.ContainerRef ?? ids[i].ToString(CultureInfo.InvariantCulture);
            var sameStep = kind switch
            {
                ContainerNextStepKinds.Complete or ContainerNextStepKinds.StartPlanned
                    => row.Kind == kind && row.MovementId == group.MovementId,
                _ => ContainerNextStepKinds.IsNewLeg(row.Kind),
            };
            if (!sameStep)
            {
                return (StepChangedMessage(name, row), "NEXT_STEP_CHANGED");
            }

            if (row.CanMove)
            {
                continue;
            }

            // A draft the reader may not confirm: the new leg's procedure decides - it plans one ("Plan only") and refuses
            // a start by name ("Container KTG-... is a draft: someone who may confirm containers must confirm it first.").
            var draftForTheProcedure = ContainerNextStepKinds.IsNewLeg(kind) && row.IsDraft && !canConfirm
                                       && row.BlockGroup == DraftNotConfirmableGroup;
            if (!draftForTheProcedure)
            {
                var reason = row.BlockedReason ?? row.BlockGroup ?? "it cannot move on now";
                return (WithName(name, reason), "CANNOT_MOVE_ON");
            }
        }

        return null;
    }

    private static string StepChangedMessage(string name, ContainerNextStepDto row) => row.Kind switch
    {
        ContainerNextStepKinds.Done => WithName(name, row.BlockedReason ?? "its journey is over"),
        ContainerNextStepKinds.Complete => $"{name} is now travelling with {row.MovementNo}: open Next step… again.",
        ContainerNextStepKinds.StartPlanned => $"{name} now waits for {row.MovementNo} ({row.MovementTypeName}): open Next step… again.",
        ContainerNextStepKinds.Receive or ContainerNextStepKinds.OpenReceipt
            => $"{name} is delivered: its goods are received next (Receive goods…).",
        _ => $"{name} has no movement of this step any more: its next step is a new leg from {row.PlaceName ?? "where it is"}. Open Next step… again.",
    };

    /* ── the words ────────────────────────────────────────────────────────────────────────────── */

    /// <summary>"KTG-2026-0031: arrived at Dar es Salaam on 17/10/2026 (MOV-2026-000046). Now At Port."</summary>
    private static string CompletionMessage(MovementDto movement, IReadOnlyList<ContainerNextStepDto> rows)
    {
        var who = Who(movement.Containers.Count, movement.Containers.FirstOrDefault()?.ContainerRef ?? rows[0].ContainerRef);
        var what = MovementStages.Normalize(movement.Stage) switch
        {
            MovementStages.Customs => $"cleared customs at {movement.ToName}",
            MovementStages.Border => $"crossed the border at {movement.ToName}",
            MovementStages.Port => $"left the port of {movement.ToName}",
            MovementStages.Origin => "loaded at the supplier",
            MovementStages.Delivery => $"delivered to {movement.ToName}",
            _ => $"arrived at {movement.ToName}",
        };
        return $"{who}: {what} on {MessageDay(movement.EndDate)} ({movement.MovementNo}).{NowStatus(movement)}";
    }

    /// <summary>"Arrival recorded; ..." - the noun of the date the dialog asked for, by the completed movement's stage.</summary>
    private static string RecordedNoun(string? stage) => MovementStages.Normalize(stage) switch
    {
        MovementStages.Customs => "Clearance",
        MovementStages.Border => "Crossing",
        MovementStages.Port => "Departure",
        MovementStages.Delivery => "Delivery",
        MovementStages.Origin => "Loading",
        _ => "Arrival",
    };

    /// <summary>
    /// "KTG-2026-0031: Inland transport Dar es Salaam → Kasumbalesa started on 17/10/2026 (MOV-2026-000051). Now In Transit."
    /// / "12 containers: ... one movement per container (MOV-2026-000051 to MOV-2026-000062)."
    /// </summary>
    private async Task<string> NewLegMessageAsync(
        IReadOnlyList<AddedLegDto> made, int containers, string? firstRef, bool started, CancellationToken cancellationToken)
    {
        if (made.Count == 0)
        {
            return "Nothing was created.";
        }

        var (leg, first) = await LegPhraseAsync(made, started, cancellationToken);
        var who = Who(containers, made.Count == 1 && containers == 1 ? made[0].ContainerRef ?? firstRef : firstRef);
        var now = made.Count == 1 && started && first is not null ? NowStatus(first) : string.Empty;
        return $"{who}: {leg}.{now}";
    }

    /// <summary>
    /// "Inland transport Dar es Salaam → Kasumbalesa started on 17/10/2026 (MOV-2026-000051)", ", one movement per container
    /// (MOV-2026-000051 to MOV-2026-000062)" for several. The first movement is read once, for the names.
    /// </summary>
    private async Task<(string Phrase, MovementDto? First)> LegPhraseAsync(
        IReadOnlyList<AddedLegDto> made, bool started, CancellationToken cancellationToken)
    {
        // The movements are committed: a failed read must not turn the answer into an error.
        MovementDto? first = null;
        try
        {
            first = await _movements.GetAsync(made[0].Id, cancellationToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogWarning(ex, "Next step: movement {MovementNo} created but not read back", made[0].MovementNo);
        }

        var leg = first is null ? "the new leg" : $"{first.TypeName} {Route(first)}";
        var when = started ? $"started on {MessageDay(made[0].StartDate)}" : $"planned for {MessageDay(made[0].PlannedDate)}";
        return made.Count == 1
            ? ($"{leg} {when} ({made[0].MovementNo})", first)
            : ($"{leg} {when}, one movement per container ({made[0].MovementNo} to {made[^1].MovementNo})", first);
    }

    /// <summary>"KTG-2026-0031" alone, else "12 containers".</summary>
    private static string Who(int count, string? onlyRef)
        => count == 1 && !string.IsNullOrEmpty(onlyRef)
            ? onlyRef
            : $"{count.ToString("N0", CultureInfo.InvariantCulture)} containers";

    /// <summary>"Dar es Salaam → Kasumbalesa", or "at Kasumbalesa" for a stay.</summary>
    private static string Route(MovementDto movement)
        => movement.FromPlaceId == movement.ToPlaceId ? $"at {movement.ToName}" : $"{movement.FromName} → {movement.ToName}";

    /// <summary>" Now At Port." - the status of its containers, or each status with its count when they differ.</summary>
    private static string NowStatus(MovementDto movement)
    {
        var statuses = movement.Containers
            .GroupBy(c => c.ContainerStatus)
            .OrderByDescending(g => g.Count())
            .Select(g => (Name: ContainerStatus.Name(g.Key), Count: g.Count()))
            .ToList();
        return statuses.Count switch
        {
            0 => string.Empty,
            1 => $" Now {statuses[0].Name}.",
            _ => $" Now {string.Join(", ", statuses.Select(s => $"{s.Name} ({s.Count})"))}.",
        };
    }

    private static string MessageDay(DateTime? value) => value?.ToString(DayFormat, CultureInfo.InvariantCulture) ?? "today";

    /// <summary>The reason as it comes, prefixed with the container when it does not name it already, with its full stop.</summary>
    private static string WithName(string name, string reason)
    {
        var text = reason.Trim();
        text = text.EndsWith('.') || text.EndsWith(')') ? text : text + ".";
        return text.Contains(name, StringComparison.Ordinal) ? text : $"{name}: {text}";
    }

    private static (int? TypeId, int? ToPlaceId)? SameProposal(IReadOnlyList<ContainerNextStepDto> rows)
    {
        var proposals = rows.Select(r => (r.ProposedTypeId, r.ProposedToPlaceId)).Distinct().ToList();
        return proposals.Count == 1 && proposals[0].ProposedTypeId is not null
            ? (proposals[0].ProposedTypeId, proposals[0].ProposedToPlaceId)
            : null;
    }

    private static NextStepMovementDto ToMovementRef(AddedLegDto leg) => new()
    {
        Id = leg.Id,
        MovementNo = leg.MovementNo,
        Status = leg.Status,
        ContainerId = leg.ContainerId,
        ContainerRef = leg.ContainerRef,
    };

    private static NextStepGroupResultDto Refused(
        NextStepGroupRequest group, string kind, IReadOnlyList<int> ids, string message, string? code) => new()
    {
        Key = group.Key,
        Kind = kind,
        Ok = false,
        Code = code,
        Message = message,
        ContainerIds = ids,
    };
}
