using System.Globalization;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Microsoft.Extensions.Logging;
using static Inventory_Shipment.Service.Implementations.LogisticsRuleFailures;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// (82) ONLY PART OF A MOVEMENT ARRIVED (shipment phase 3). The containers that arrived leave the movement in progress for
/// their own - a copy with the same header and start date (logistics.usp_Movement_SplitContainers) - which is then
/// completed through <see cref="SetStatusAsync"/>, the movement's own Complete: the only place that drafts a Delivery's
/// goods receipts after the commit (script 79's switch included). The others stay on the original, in progress.
/// <list type="bullet">
///   <item>THE COMPLETION DATE IS CHECKED BEFORE ANYTHING IS SPLIT: the procedure refuses a date in the future or before
///   the start (Complete's own rules and words) before it moves a container, so a refused date leaves both movements as
///   they were.</item>
///   <item>ONCE ASKED, A SPLIT RUNS TO ITS END: the split and the completion of its movement run without the request's
///   cancellation, so a client that goes away never leaves the containers on their own movement still in progress
///   unseen. Should the completion be refused all the same, the answer says exactly what happened: "MOV-2026-000052 was
///   split off MOV-2026-000046 but not completed: {reason}. Complete it on its page."</item>
///   <item>A SPLIT COMMITTED IS ALWAYS SAID, whatever fails after it: a refusal, but also an error that is no business rule
///   (a deadlock retried three times, a timeout, a lost connection, a read after the commit). The movement is read again
///   for what the database kept: completed after all (the failure came after the completion, e.g. the read after a
///   Delivery's draft goods receipts), it is answered as completed with what is missing; else as split, not completed,
///   with that movement - never as a step that did nothing.</item>
/// </list>
/// </summary>
public sealed partial class MovementService
{
    /// <summary>
    /// A row version that is sent but cannot be one (not 8 bytes of base64): refused, never read as "not sent" - that would
    /// skip the concurrency check of a split. (The older endpoints keep reading it as not sent.)
    /// </summary>
    private const string InvalidRowVersionMessage = "The row version is not valid. Reload the page and try again.";

    public async Task<Result<MovementSplitResultDto>> CompleteSomeAsync(
        int id, CompleteSomeContainersRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.MovementsManage))
        {
            return Forbidden<MovementSplitResultDto>(Permissions.Containers.MovementsManage);
        }

        var ids = (request.ContainerIds ?? []).Distinct().ToList();
        if (ids.Count == 0)
        {
            return Result<MovementSplitResultDto>.Failure(ErrorType.Validation, "Tick the containers that arrived.", "VALIDATION");
        }

        if (InvalidContainerIds(ids) is { } invalid)
        {
            return Result<MovementSplitResultDto>.Failure(ErrorType.Validation, invalid, "VALIDATION");
        }

        if (IsInvalidRowVersion(request.RowVersion))
        {
            return Result<MovementSplitResultDto>.Failure(ErrorType.Validation, InvalidRowVersionMessage, "VALIDATION");
        }

        var outcome = await SplitAndCompleteAsync(id, ids, request.Date, request.RowVersion, userId, permissions);
        if (outcome.Refusal is { } refusal)
        {
            return Result<MovementSplitResultDto>.Failure(refusal.Type, refusal.Message, refusal.Code);
        }

        var split = outcome.Split!;
        if (outcome.Completed is { } movement)
        {
            return Result<MovementSplitResultDto>.Success(new MovementSplitResultDto
            {
                Ok = true,
                Message = SplitCompletionMessage(movement, split),
                OriginalMovementId = split.OriginalMovementId,
                OriginalMovementNo = split.OriginalMovementNo,
                RemainingContainerCount = split.ContainersLeft,
                MovementId = split.NewId,
                MovementNo = split.MovementNo,
                Movement = movement,
                Warnings = movement.Warnings,
            });
        }

        // Split, not completed: the containers are on their own movement, in progress - said, with that movement (read
        // again best effort: null when the database did not answer, its id and number still given).
        return Result<MovementSplitResultDto>.Success(new MovementSplitResultDto
        {
            Ok = false,
            Code = outcome.CompletionCode,
            Message = NotCompletedMessage(split, outcome.CompletionError),
            OriginalMovementId = split.OriginalMovementId,
            OriginalMovementNo = split.OriginalMovementNo,
            RemainingContainerCount = split.ContainersLeft,
            MovementId = split.NewId,
            MovementNo = split.MovementNo,
            Movement = outcome.Current,
        });
    }

    /// <summary>What a split asked for came to: refused before anything changed, or split and then completed or not.</summary>
    private sealed record SplitOutcome
    {
        /// <summary>The split was refused: nothing changed.</summary>
        public RuleFailure? Refusal { get; init; }

        /// <summary>The split, committed.</summary>
        public MovementSplitDto? Split { get; init; }

        /// <summary>The containers' own movement, completed (with a Delivery's goods receipts); null when refused.</summary>
        public MovementDto? Completed { get; init; }

        public string? CompletionError { get; init; }
        public string? CompletionCode { get; init; }

        /// <summary>Split, not completed: the containers' own movement as read again (null when it could not be read).</summary>
        public MovementDto? Current { get; init; }
    }

    /// <summary>
    /// The split, then the completion of its movement on the same date - neither cut short by the request (see the class).
    /// The date is the request's, else today: the procedure checks it before it splits, and the completion takes the same.
    /// </summary>
    private async Task<SplitOutcome> SplitAndCompleteAsync(
        int movementId, IReadOnlyList<int> ids, DateOnly? date, string? rowVersion, int userId, IReadOnlySet<string> permissions)
    {
        var completeOn = date ?? DateOnly.FromDateTime(DateTime.UtcNow);

        MovementSplitDto split;
        try
        {
            split = await _movements.SplitContainersAsync(movementId, ids, ToRowVersion(rowVersion), completeOn, userId, CancellationToken.None);
        }
        catch (BusinessRuleException ex)
        {
            return new SplitOutcome { Refusal = Describe(ex) };
        }

        _logger.LogInformation("Movement {MovementNo}: {Moved} container(s) split off into {NewMovementNo} by user {UserId}, {Left} left on it",
            split.OriginalMovementNo, split.ContainersMoved, split.MovementNo, userId, split.ContainersLeft);

        // FROM HERE THE SPLIT IS COMMITTED: whatever fails, the answer says it (see the class).
        Result<MovementDto> completed;
        try
        {
            completed = await SetStatusAsync(
                split.NewId, "Complete",
                new MovementStatusRequest { Date = completeOn, RowVersion = Convert.ToBase64String(split.RowVersion) },
                userId, permissions, CancellationToken.None);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogError(ex, "Movement {NewMovementNo} was split off {MovementNo}, and its completion failed", split.MovementNo, split.OriginalMovementNo);
            var now = await ReadBackAsync(split.NewId);
            if (now is { Status: MovementStatus.Completed })
            {
                // The completion committed: what failed came after it (its read, a Delivery's draft goods receipts).
                return new SplitOutcome { Split = split, Completed = CompletedDespiteFailure(now) };
            }

            return new SplitOutcome { Split = split, CompletionError = DatabaseDidNotAnswer, CompletionCode = "UNEXPECTED", Current = now };
        }

        if (completed.IsSuccess && completed.Value is { } movement)
        {
            return new SplitOutcome { Split = split, Completed = movement };
        }

        _logger.LogWarning("Movement {NewMovementNo} was split off {MovementNo} but not completed: {Reason}",
            split.MovementNo, split.OriginalMovementNo, completed.Error);
        return new SplitOutcome
        {
            Split = split,
            CompletionError = completed.Error ?? "the movement was not completed",
            CompletionCode = completed.Code,
            Current = await ReadBackAsync(split.NewId),
        };
    }

    /// <summary>The movement as the database has it now, or null when it does not answer (logged): the answer goes out all the same.</summary>
    private async Task<MovementDto?> ReadBackAsync(int id)
    {
        try
        {
            return await _movements.GetAsync(id, CancellationToken.None);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogWarning(ex, "Movement {MovementId} could not be read back after its split", id);
            return null;
        }
    }

    /// <summary>
    /// A split-off movement that IS completed although its completion call failed after the commit: the movement as read
    /// again is the whole answer, except for a Delivery - its draft goods receipts were made after the commit, and the
    /// failure may have come before them (none made: say it, as when they fail) or after them (made: their list is lost).
    /// </summary>
    private static MovementDto CompletedDespiteFailure(MovementDto movement)
    {
        if (MovementStages.Normalize(movement.Stage) != MovementStages.Delivery)
        {
            return movement;
        }

        if (!movement.GoodsReceiptsAutomatic)
        {
            return movement with { GoodsReceipts = [], GoodsReceiptsMessage = ByHandMessage };
        }

        var withoutReceipt = movement.Containers.Any(c => c.GoodsReceiptId is null && c.ContainerStatus is >= 2 and <= 5);
        var warning = withoutReceipt
            ? $"The movement is completed, but its draft goods receipts were not created: {DatabaseDidNotAnswer}. "
              + "Use Receive goods… on each container."
            : $"The movement is completed and its draft goods receipts are made, but their list could not be read: {DatabaseDidNotAnswer}. "
              + "Find them in Purchase › Goods Receipts.";
        return movement with { GoodsReceipts = [], Warnings = [.. movement.Warnings, warning] };
    }

    /// <summary>A row version sent but not readable as one (see <see cref="InvalidRowVersionMessage"/>).</summary>
    private static bool IsInvalidRowVersion(string? rowVersion)
        => !string.IsNullOrWhiteSpace(rowVersion) && ToRowVersion(rowVersion) is null;

    /// <summary>
    /// A Complete group of the next step with splitOff: the ticked containers arrive alone, then the "Then" leg for them as
    /// for any completion. Refused before the split: the group is refused, nothing changed. Split but not completed: the
    /// group is said refused with what happened, and their own movement in Movements.
    /// </summary>
    private async Task<NextStepGroupResultDto> SplitOffGroupAsync(
        NextStepGroupRequest group, IReadOnlyList<int> ids, bool canConfirm, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken)
    {
        var outcome = await SplitAndCompleteAsync(group.MovementId!.Value, ids, group.Date, group.RowVersion, userId, permissions);
        if (outcome.Refusal is { } refusal)
        {
            return Refused(group, ContainerNextStepKinds.Complete, ids, refusal.Message, refusal.Code);
        }

        var split = outcome.Split!;
        if (outcome.Completed is not { } movement)
        {
            return new NextStepGroupResultDto
            {
                Key = group.Key,
                Kind = ContainerNextStepKinds.Complete,
                Ok = false,
                Code = outcome.CompletionCode,
                Message = NotCompletedMessage(split, outcome.CompletionError),
                ContainerIds = ids,
                Movements = [new NextStepMovementDto { Id = split.NewId, MovementNo = split.MovementNo, Status = outcome.Current?.Status ?? split.Status }],
                SplitFromMovementId = split.OriginalMovementId,
                SplitFromMovementNo = split.OriginalMovementNo,
                RemainingContainerCount = split.ContainersLeft,
            };
        }

        var (message, thenMovements, warnings) = await AfterCompletionAsync(
            group, ids, movement, SplitCompletionMessage(movement, split), canConfirm, userId, cancellationToken);
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
            SplitFromMovementId = split.OriginalMovementId,
            SplitFromMovementNo = split.OriginalMovementNo,
            RemainingContainerCount = split.ContainersLeft,
        };
    }

    /// <summary>
    /// "KTG-2026-0031: arrived at Dar es Salaam on 17/10/2026 with MOV-2026-000052 (split off MOV-2026-000046). Now At Port.
    /// The 11 others are still on MOV-2026-000046."
    /// </summary>
    private static string SplitCompletionMessage(MovementDto movement, MovementSplitDto split)
    {
        var who = Who(movement.Containers.Count, movement.Containers.FirstOrDefault()?.ContainerRef);
        var others = split.ContainersLeft == 1
            ? $"The other container is still on {split.OriginalMovementNo}."
            : $"The {split.ContainersLeft.ToString("N0", CultureInfo.InvariantCulture)} others are still on {split.OriginalMovementNo}.";
        return $"{who}: {CompletedWhat(movement)} on {MessageDay(movement.EndDate)} with {movement.MovementNo} "
               + $"(split off {split.OriginalMovementNo}).{NowStatus(movement)} {others}";
    }

    /// <summary>"MOV-2026-000052 was split off MOV-2026-000046 but not completed: {reason}. Complete it on its page."</summary>
    private static string NotCompletedMessage(MovementSplitDto split, string? reason)
        => $"{split.MovementNo} was split off {split.OriginalMovementNo} but not completed: "
           + $"{WithoutFinalPeriod(reason ?? "the movement was not completed")}. Complete it on its page.";
}
