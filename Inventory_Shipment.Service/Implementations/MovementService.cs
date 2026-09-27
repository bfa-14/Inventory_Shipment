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

public sealed class MovementService : IMovementService
{
    private const string NotFoundMessage = "Movement not found.";

    /// <summary>The procedure's page ceiling; the export walks the pages at this size.</summary>
    private const int ExportPageSize = 200;

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
        if (!permissions.Contains(Permissions.Containers.View))
        {
            return Forbidden<PagedResult<MovementListDto>>(Permissions.Containers.View);
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
        if (!permissions.Contains(Permissions.Containers.View))
        {
            return Forbidden<MovementDto>(Permissions.Containers.View);
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

    /* ── export ───────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        MovementQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.View))
        {
            return Forbidden<(byte[], string)>(Permissions.Containers.View);
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

        try
        {
            await _movements.SetStatusAsync(
                id, action, request.Date, request.Reason, ToRowVersion(request.RowVersion), userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<MovementDto>(ex);
        }

        _logger.LogInformation("Movement {MovementId}: {Action} by user {UserId}", id, action, userId);
        return await ReadAsync(id, cancellationToken);
    }
}
