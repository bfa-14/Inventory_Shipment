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

public sealed class ContainerChargeService : IContainerChargeService
{
    private const string NotFoundMessage = "Charge not found.";

    /// <summary>The procedure's page ceiling; the export walks the pages at this size.</summary>
    private const int ExportPageSize = 200;

    private readonly IContainerChargeRepository _charges;
    private readonly ILogger<ContainerChargeService> _logger;

    public ContainerChargeService(IContainerChargeRepository charges, ILogger<ContainerChargeService> logger)
    {
        _charges = charges;
        _logger = logger;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<ContainerChargePageDto>> SearchAsync(
        ContainerChargeQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.ChargesView))
        {
            return Forbidden<ContainerChargePageDto>(Permissions.Containers.ChargesView);
        }

        if (InvalidStatus(query) is { } invalid)
        {
            return Result<ContainerChargePageDto>.Failure(ErrorType.Validation, invalid, "VALIDATION");
        }

        var (items, totalCount, totalAmountBase) = await _charges.SearchAsync(query, cancellationToken);

        return Result<ContainerChargePageDto>.Success(new ContainerChargePageDto
        {
            Items = items,
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount,
            TotalAmountBase = totalAmountBase,
        });
    }

    public async Task<Result<ContainerChargeDto>> GetAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.ChargesView))
        {
            return Forbidden<ContainerChargeDto>(Permissions.Containers.ChargesView);
        }

        return await ReadAsync(id, cancellationToken);
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<IReadOnlyList<ContainerChargeGroupMemberDto>>> CreateAsync(
        CreateContainerChargeRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.ChargesCreate))
        {
            return Forbidden<IReadOnlyList<ContainerChargeGroupMemberDto>>(Permissions.Containers.ChargesCreate);
        }

        IReadOnlyList<ContainerChargeGroupMemberDto> created;
        try
        {
            created = await _charges.CreateAsync(request, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<ContainerChargeGroupMemberDto>>(ex);
        }

        _logger.LogInformation("Container charge created on {Count} container(s) by user {UserId}", created.Count, userId);
        return Result<IReadOnlyList<ContainerChargeGroupMemberDto>>.Success(created);
    }

    public Task<Result<ContainerChargeDto>> UpdateAsync(
        int id, UpdateContainerChargeRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => ChangeAsync(id, Permissions.Containers.ChargesCreate, permissions, userId, "updated", cancellationToken,
            () => _charges.UpdateAsync(id, request, userId, cancellationToken));

    public Task<Result<ContainerChargeDto>> PostAsync(
        int id, ChargeActionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => ChangeAsync(id, Permissions.Containers.ChargesPost, permissions, userId, "posted", cancellationToken,
            () => _charges.PostAsync(id, [], ToRowVersion(request.RowVersion), userId, cancellationToken));

    /// <summary>ALL OR NOTHING: one draft that cannot be posted refuses the whole batch, with the procedure's reason.</summary>
    public async Task<Result<IReadOnlyList<ContainerChargeDto>>> PostManyAsync(
        PostChargesRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.ChargesPost))
        {
            return Forbidden<IReadOnlyList<ContainerChargeDto>>(Permissions.Containers.ChargesPost);
        }

        var ids = request.Ids.Distinct().ToList();
        if (ids.Count == 0)
        {
            return Result<IReadOnlyList<ContainerChargeDto>>.Failure(
                ErrorType.Validation, "Select at least one charge to post.", "VALIDATION");
        }

        try
        {
            await _charges.PostAsync(null, ids, null, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<ContainerChargeDto>>(ex);
        }

        _logger.LogInformation("{Count} container charge(s) posted by user {UserId}", ids.Count, userId);

        var posted = new List<ContainerChargeDto>(ids.Count);
        foreach (var id in ids)
        {
            if (await _charges.GetAsync(id, cancellationToken) is { } charge)
            {
                posted.Add(charge);
            }
        }

        return Result<IReadOnlyList<ContainerChargeDto>>.Success(posted);
    }

    public Task<Result<ContainerChargeDto>> CancelAsync(
        int id, CancelRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => ChangeAsync(id, Permissions.Containers.ChargesCancel, permissions, userId, "cancelled", cancellationToken,
            () => _charges.CancelAsync(id, request.Reason, ToRowVersion(request.RowVersion), userId, cancellationToken));

    public async Task<Result> DeleteAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.ChargesCreate))
        {
            return Forbidden<ContainerChargeDto>(Permissions.Containers.ChargesCreate);
        }

        try
        {
            await _charges.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }

        _logger.LogInformation("Container charge {ChargeId} deleted by user {UserId}", id, userId);
        return Result.Success();
    }

    /* ── export ───────────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        ContainerChargeQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.ChargesView))
        {
            return Forbidden<(byte[], string)>(Permissions.Containers.ChargesView);
        }

        if (InvalidStatus(query) is { } invalid)
        {
            return Result<(byte[], string)>.Failure(ErrorType.Validation, invalid, "VALIDATION");
        }

        var rows = new List<ContainerChargeListDto>();
        var totalBase = 0m;
        for (var page = 1; ; page++)
        {
            var (items, total, amountBase) = await _charges.SearchAsync(
                new ContainerChargeQuery
                {
                    Search = query.Search, ContainerId = query.ContainerId, MovementId = query.MovementId,
                    ChargeTypeId = query.ChargeTypeId, ProviderPartyId = query.ProviderPartyId, Status = query.Status,
                    DateFrom = query.DateFrom, DateTo = query.DateTo, SortBy = query.SortBy, SortDir = query.SortDir,
                    Page = page, PageSize = ExportPageSize,
                },
                cancellationToken);

            if (page == 1)
            {
                totalBase = amountBase;
            }

            rows.AddRange(items);
            if (items.Count < ExportPageSize || rows.Count >= total)
            {
                break;
            }
        }

        return Result<(byte[], string)>.Success(
            (BuildWorkbook(rows, totalBase), $"ContainerCharges_{DateTime.UtcNow:yyyyMMdd}.xlsx"));
    }

    private static byte[] BuildWorkbook(IReadOnlyList<ContainerChargeListDto> rows, decimal totalBase)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Container Charges");

        string[] columns =
        [
            "Date", "Container", "Container No.", "Movement", "Charge Type", "Description", "Provider", "Reference",
            "Amount", "Currency", "Rate", "Amount (base)", "Method", "In Cost", "Status", "After Offload", "Documents",
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
        foreach (var c in rows)
        {
            row++;
            XLCellValue[] values =
            [
                c.ChargeDate.ToString("dd/MM/yyyy"), c.ContainerRef, c.ContainerNo ?? string.Empty, c.MovementNo ?? string.Empty,
                $"{c.ChargeCode} - {c.ChargeName}", c.Description ?? string.Empty, c.ProviderName ?? string.Empty,
                c.Reference ?? string.Empty, c.Amount, c.CurrencyCode, c.ExchangeRate, c.AmountBase, c.AllocationMethod,
                c.IncludeInLandedCost ? "Yes" : "No", c.StatusName, c.AdjustedAfterOffload ? "Yes" : string.Empty,
                c.AttachmentCount,
            ];
            for (var i = 0; i < values.Length; i++)
            {
                sheet.Cell(row, i + 1).Value = values[i];
            }
        }

        // The total of the filter, under the base amount column.
        row += 2;
        sheet.Cell(row, 11).Value = "Total (base)";
        sheet.Cell(row, 11).Style.Font.Bold = true;
        sheet.Cell(row, 12).Value = totalBase;
        sheet.Cell(row, 12).Style.Font.Bold = true;

        sheet.Column(9).Style.NumberFormat.Format = "#,##0.00";
        sheet.Column(12).Style.NumberFormat.Format = "#,##0.00";
        sheet.Columns().AdjustToContents();

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    /* ── the shared shapes ────────────────────────────────────────────────────────────────────── */

    private static string? InvalidStatus(ContainerChargeQuery query)
        => !string.IsNullOrWhiteSpace(query.Status) && ContainerChargeStatus.ToCode(query.Status) is null
            ? "status must be 1-3 or Draft, Posted, Cancelled."
            : null;

    private async Task<Result<ContainerChargeDto>> ReadAsync(int id, CancellationToken cancellationToken)
    {
        var charge = await _charges.GetAsync(id, cancellationToken);
        return charge is null
            ? Result<ContainerChargeDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<ContainerChargeDto>.Success(charge);
    }

    /// <summary>Permission, the procedure, then a re-read: posting or cancelling moves the split and the flags.</summary>
    private async Task<Result<ContainerChargeDto>> ChangeAsync(
        int id, string permission, IReadOnlySet<string> permissions, int userId, string verb,
        CancellationToken cancellationToken, Func<Task> change)
    {
        if (!permissions.Contains(permission))
        {
            return Forbidden<ContainerChargeDto>(permission);
        }

        try
        {
            await change();
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ContainerChargeDto>(ex);
        }

        _logger.LogInformation("Container charge {ChargeId} {Verb} by user {UserId}", id, verb, userId);
        return await ReadAsync(id, cancellationToken);
    }
}
