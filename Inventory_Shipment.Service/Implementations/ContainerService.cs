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

public sealed class ContainerService : IContainerService
{
    private const string NotFoundMessage = "Container not found.";

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

    public async Task<Result<IReadOnlyList<AvailableInvoiceDto>>> GetAvailableInvoicesAsync(
        AvailableInvoiceQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.Create))
        {
            return Forbidden<IReadOnlyList<AvailableInvoiceDto>>(Permissions.Containers.Create);
        }

        return Result<IReadOnlyList<AvailableInvoiceDto>>.Success(
            await _containers.GetAvailableInvoicesAsync(query, cancellationToken));
    }

    public async Task<Result<IReadOnlyList<AvailableInvoiceLineDto>>> GetInvoiceLinesAsync(
        int invoiceId, int? containerId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.Create))
        {
            return Forbidden<IReadOnlyList<AvailableInvoiceLineDto>>(Permissions.Containers.Create);
        }

        var lines = await _containers.GetInvoiceLinesAsync(invoiceId, containerId, cancellationToken);
        return lines is null
            ? Result<IReadOnlyList<AvailableInvoiceLineDto>>.Failure(ErrorType.NotFound, "Purchase invoice not found.", "NOT_FOUND")
            : Result<IReadOnlyList<AvailableInvoiceLineDto>>.Success(lines);
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
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

    /// <summary>RECORDING THE ROUTE IS EDITING THE CONTAINER, so it is the create right — the same person follows the shipment.</summary>
    public Task<Result<ContainerDto>> AddEventAsync(
        int id, AddEventRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (ContainerEventTypes.Normalize(request.EventType) is null)
        {
            return Task.FromResult(Result<ContainerDto>.Failure(
                ErrorType.Validation,
                $"Event type must be one of {string.Join(", ", ContainerEventTypes.UserRecordable)} (the offload writes its own event).",
                "VALIDATION"));
        }

        return ChangeAsync(id, Permissions.Containers.Create, permissions, userId, $"event {request.EventType}", cancellationToken,
            () => _containers.AddEventAsync(id, request, userId, cancellationToken));
    }

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

    /* ── attachments ──────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<int>> AddFileAsync(
        int id, ContainerFileUpload upload, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.Create))
        {
            return Forbidden<int>(Permissions.Containers.Create);
        }

        try
        {
            return Result<int>.Success(await _containers.AddFileAsync(id, upload, userId, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<int>(ex);
        }
    }

    public async Task<Result<ContainerFileContent>> GetFileAsync(
        int fileId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.View))
        {
            return Forbidden<ContainerFileContent>(Permissions.Containers.View);
        }

        var file = await _containers.GetFileAsync(fileId, cancellationToken);
        return file is null
            ? Result<ContainerFileContent>.Failure(ErrorType.NotFound, "File not found.", "NOT_FOUND")
            : Result<ContainerFileContent>.Success(file);
    }

    public async Task<Result> DeleteFileAsync(
        int fileId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Containers.Create))
        {
            return Forbidden<ContainerDto>(Permissions.Containers.Create);
        }

        try
        {
            await _containers.DeleteFileAsync(fileId, userId, cancellationToken);
            return Result.Success();
        }
        catch (BusinessRuleException ex)
        {
            return Failure(ex);
        }
    }

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
    /// B/L, capacity, operations), the invoices it carries, and the lines loaded — with what was
    /// received once it has been offloaded.
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
            ("Max Units", container.MaxUnits?.ToString() ?? string.Empty),
            ("Allocated Units", container.TotalAllocatedBase.ToString()),
            ("Utilization", container.UtilizationPct is { } pct ? $"{pct:0.##} %" : string.Empty),
            ("Total Oil", container.TotalOilQty.ToString("0.##")),
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
            ["PI No.", "PI Date", "Supplier", "Commercial Invoice No.", "Exporter Ref.", "Currency", "PI Qty", "Loaded Here", "Loaded (all)", "Remaining", "Total Amount"],
            container.Invoices.Select(i => new XLCellValue[]
            {
                i.DocumentNumber ?? "DRAFT", Day(i.DocumentDate), i.SupplierName, i.CommercialInvoiceNo ?? string.Empty,
                i.ExporterReference ?? string.Empty, i.CurrencyCode, i.TotalQtyBase, i.AllocatedHereBase,
                i.AllocatedTotalBase, i.RemainingBase, i.TotalAmount,
            }));

        WriteTable(workbook.AddWorksheet("Lines"),
            ["#", "PI No.", "Supplier", "Item Code", "Item Name", "Model", "Unit", "Qty", "Qty (base)", "Oil", "Oil / Unit", "Total Oil", "Received (base)", "Variance Reason", "Notes"],
            container.Lines.Select(l => new XLCellValue[]
            {
                l.LineNumber, l.InvoiceNumber ?? string.Empty, l.SupplierName, l.ItemCode, l.ItemName, l.Model ?? string.Empty,
                l.PackingFormula > 1 ? $"{l.UnitTypeName} (x{l.PackingFormula})" : l.UnitTypeName,
                l.Quantity, l.QuantityBase, l.OilIncluded ? "Yes" : "No",
                l.OilQtyPerUnit is { } oil ? oil : Blank.Value, l.TotalOilQty,
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

    /* ── the shared shapes ────────────────────────────────────────────────────────────────────── */

    private async Task<Result<ContainerDto>> ReadAsync(int id, CancellationToken cancellationToken)
    {
        var container = await _containers.GetAsync(id, cancellationToken);
        return container is null
            ? Result<ContainerDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<ContainerDto>.Success(container);
    }

    /// <summary>
    /// Permission, then the procedure, then a re-read: an event moves the derived status and the
    /// location, an offload writes the received quantities — the answer is the server's container,
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
