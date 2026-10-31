using System.IO.Compression;
using System.Text.Json;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Reports;
using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Reports › Attachment Report (script 101): every module's attachments, filtered by type and by two date ranges, listed
/// a page at a time, downloaded one, several or all at once.
///
/// WHAT A READER SEES IS WHAT THEY MAY ALREADY OPEN. The report's permission opens the page; each file then shows only to
/// a reader who may view its document (a supplier payment's files with View Supplier Payments, ...), the same permission
/// that guards that document's own download. The kinds are worked out here and passed to every procedure, so the list,
/// the count and every download obey the same rule - a key sent for a file the reader may not open is simply not found.
/// </summary>
public sealed class AttachmentReportService : IAttachmentReportService
{
    private const string ForbiddenCode = "FORBIDDEN";
    private const string ZipContentType = "application/zip";

    /// <summary>Each document kind, the permission that opens its documents, what it is called and its page.</summary>
    private static readonly IReadOnlyList<(string Kind, string Permission, string Name, string? Path)> Kinds =
    [
        ("CONTAINER", Permissions.Containers.View, "Container", "/logistics/containers/"),
        ("PO", Permissions.Purchase.OrdersView, "Purchase order", "/purchase/orders/"),
        ("PINV", Permissions.Purchase.InvoicesView, "Purchase invoice", "/purchase/invoices/"),
        ("PRET", Permissions.Purchase.ReturnsView, "Purchase return", "/purchase/returns/"),
        ("GRN", Permissions.Purchase.GoodsReceiptsView, "Goods receipt", "/purchase/goods-receipts/"),
        ("PAY", Permissions.Purchase.PaymentsView, "Supplier payment", "/purchase/payments/"),
        ("SINV", Permissions.Sales.InvoicesView, "Sales invoice", "/sales/invoices/"),
        ("SRET", Permissions.Sales.InvoicesView, "Sales return", "/sales/invoices/"),
        ("SO", Permissions.Sales.InvoicesView, "Sales order", null),
        ("RCPT", Permissions.Sales.ReceiptsView, "Receipt", "/sales/receipts/"),
        ("INV_IN", Permissions.Inventory.StockInView, "Inventory In", "/inventory/stock-in/"),
        ("INV_OUT", Permissions.Inventory.StockOutView, "Inventory Out", "/inventory/stock-out/"),
        ("BIV_OUT", Permissions.Inventory.BivacOutView, "BIVAC Out", "/inventory/bivac-out/"),
        ("TRO", Permissions.Inventory.TransfersView, "Transfer order", "/inventory/transfers/"),
        ("TRD", Permissions.Inventory.TransfersView, "Transfer dispatch", "/inventory/transfers/"),
        ("TRR", Permissions.Inventory.TransfersView, "Transfer receipt", "/inventory/transfers/"),
        ("ITEM", Permissions.Inventory.ItemsView, "Item", "/inventory/items/"),
    ];

    private static readonly char[] InvalidNameChars = [.. Path.GetInvalidFileNameChars(), '/', '\\'];

    private readonly IAttachmentReportRepository _reports;
    private readonly ReportsOptions _options;
    private readonly ILogger<AttachmentReportService> _logger;

    public AttachmentReportService(
        IAttachmentReportRepository reports, IOptions<ReportsOptions> options, ILogger<AttachmentReportService> logger)
    {
        _reports = reports;
        _options = options.Value;
        _logger = logger;
    }

    public async Task<Result<AttachmentReportResult>> ListAsync(
        AttachmentReportQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (Refuse(permissions) is { } refused) return Result<AttachmentReportResult>.Failure(ErrorType.Forbidden, refused, ForbiddenCode);
        if (ValidateDates(query) is { } invalid) return Result<AttachmentReportResult>.Failure(ErrorType.Validation, invalid, "VALIDATION");

        var kinds = KindsFor(permissions);
        var (rows, total, bytes) = kinds.Count == 0
            ? ([], 0, 0L)
            : await _reports.ListAsync(query, kinds, cancellationToken);

        foreach (var row in rows) Describe(row);

        return Result<AttachmentReportResult>.Success(new AttachmentReportResult
        {
            Items = rows,
            TotalCount = total,
            TotalBytes = bytes,
            Page = query.Page,
            PageSize = query.PageSize,
            MaxFiles = _options.AttachmentZipMaxFiles,
            MaxBytes = _options.AttachmentZipMaxBytes,
            ZipFileName = ZipName(query),
        });
    }

    public async Task<Result<IReadOnlyList<AttachmentReportTypeDto>>> TypesAsync(
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (Refuse(permissions) is { } refused)
        {
            return Result<IReadOnlyList<AttachmentReportTypeDto>>.Failure(ErrorType.Forbidden, refused, ForbiddenCode);
        }

        return Result<IReadOnlyList<AttachmentReportTypeDto>>.Success(await _reports.TypesAsync(cancellationToken));
    }

    public async Task<Result<AttachmentDownloadFile>> DownloadAsync(
        AttachmentDownloadRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (Refuse(permissions) is { } refused) return Result<AttachmentDownloadFile>.Failure(ErrorType.Forbidden, refused, ForbiddenCode);
        if (ValidateDates(request) is { } invalid) return Result<AttachmentDownloadFile>.Failure(ErrorType.Validation, invalid, "VALIDATION");

        var keys = request.All ? null : (request.Keys ?? []).Where(k => !string.IsNullOrWhiteSpace(k)).Select(k => k.Trim()).Distinct().ToList();
        if (keys is { Count: 0 })
        {
            return Result<AttachmentDownloadFile>.Failure(ErrorType.Validation, "Choose at least one attachment to download.", "VALIDATION");
        }

        var kinds = KindsFor(permissions);
        var files = kinds.Count == 0 ? [] : await _reports.FilesAsync(request, keys, kinds, cancellationToken);
        if (files.Count == 0)
        {
            return Result<AttachmentDownloadFile>.Failure(ErrorType.NotFound, "No attachment matches: nothing to download.", "NOT_FOUND");
        }

        /* THE LIMIT IS CHECKED BEFORE ANY BYTE IS READ: the files live in the database, and a ZIP of thousands of them is
           one long request that holds the API and SQL Server. The reader narrows the filters instead. */
        var totalBytes = files.Sum(f => f.SizeBytes);
        if (files.Count > _options.AttachmentZipMaxFiles || totalBytes > _options.AttachmentZipMaxBytes)
        {
            return Result<AttachmentDownloadFile>.Failure(ErrorType.Conflict,
                $"{files.Count} files ({SizeLabel(totalBytes)}) are more than one download may take " +
                $"({_options.AttachmentZipMaxFiles} files or {SizeLabel(_options.AttachmentZipMaxBytes)}). " +
                "Narrow the filters (fewer types or a shorter date range) and download again.", "TOO_LARGE");
        }

        foreach (var file in files) Describe(file);

        var mode = request.All ? "All" : "Selected";
        var criteria = request.All
            ? JsonSerializer.Serialize(new
            {
                request.TypeIds,
                request.DocumentDateFrom,
                request.DocumentDateTo,
                request.UploadedFrom,
                request.UploadedTo,
            })
            : JsonSerializer.Serialize(files.Select(f => f.Key));
        await _reports.LogDownloadAsync(userId, mode, files.Count, totalBytes, criteria, cancellationToken);
        _logger.LogInformation(
            "Attachment Report: user {UserId} downloads {FileCount} file(s), {TotalBytes} bytes ({Mode})", userId, files.Count, totalBytes, mode);

        // One chosen file comes back as itself; "Download all" and several files are a ZIP.
        if (!request.All && files.Count == 1)
        {
            var only = files[0];
            var buffer = TempFile();
            await _reports.ReadContentsAsync([only.Key], async (_, content) => await content.CopyToAsync(buffer, cancellationToken), cancellationToken);
            buffer.Position = 0;
            return Result<AttachmentDownloadFile>.Success(new AttachmentDownloadFile
            {
                Content = buffer,
                FileName = only.DownloadName,
                ContentType = string.IsNullOrWhiteSpace(only.ContentType) ? "application/octet-stream" : only.ContentType,
            });
        }

        /* THE ZIP IS WRITTEN TO A TEMPORARY FILE, not to memory and not straight to the response: a 2 GB set never sits in
           the API's memory, the browser gets a Content-Length (its download bar can show progress), and the file is
           deleted as soon as the response has sent it. */
        var zip = TempFile();
        var names = files.ToDictionary(f => f.Key, f => f.DownloadName);
        using (var archive = new ZipArchive(zip, ZipArchiveMode.Create, leaveOpen: true))
        {
            var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            await _reports.ReadContentsAsync(names.Keys.ToList(), async (key, content) =>
            {
                var entry = archive.CreateEntry(Unique(names[key], used), CompressionLevel.Fastest);
                await using var target = entry.Open();
                await content.CopyToAsync(target, cancellationToken);
            }, cancellationToken);
        }

        zip.Position = 0;
        return Result<AttachmentDownloadFile>.Success(new AttachmentDownloadFile
        {
            Content = zip,
            FileName = request.All ? ZipName(request) : $"attachments_selected_{DateTime.UtcNow:yyyy-MM-dd}.zip",
            ContentType = ZipContentType,
        });
    }

    // ----- helpers -----

    private static string? Refuse(IReadOnlySet<string> permissions)
        => permissions.Contains(Permissions.Reports.AttachmentsView)
            ? null
            : $"This action needs the {Permissions.Reports.AttachmentsView} permission.";

    private static string? ValidateDates(AttachmentReportFilters filters)
    {
        if (filters.DocumentDateFrom is { } df && filters.DocumentDateTo is { } dt && df > dt)
        {
            return "The document date from is after the document date to.";
        }

        if (filters.UploadedFrom is { } uf && filters.UploadedTo is { } ut && uf > ut)
        {
            return "The upload date from is after the upload date to.";
        }

        return null;
    }

    private static IReadOnlyCollection<string> KindsFor(IReadOnlySet<string> permissions)
        => Kinds.Where(k => permissions.Contains(k.Permission)).Select(k => k.Kind).ToList();

    /// <summary>The key, the kind's name, the page, the type's label and the name the file downloads under.</summary>
    private static void Describe(AttachmentReportRowDto row)
    {
        row.Key = $"{row.Source}:{row.Id}";
        row.UploadedAtUtc = DateTime.SpecifyKind(row.UploadedAtUtc, DateTimeKind.Utc);

        var kind = Kinds.FirstOrDefault(k => k.Kind == row.DocumentKind);
        row.DocumentKindName = kind.Name ?? row.DocumentKind;
        row.OwnerPath = kind.Path is null ? null : kind.Path + row.OwnerId;

        row.TypeLabel = string.IsNullOrWhiteSpace(row.TypeCategory)
            ? "Other"
            : string.IsNullOrWhiteSpace(row.TypeSubType) ? row.TypeCategory! : $"{row.TypeCategory} › {row.TypeSubType}";

        /* "KTG-2026-0031 - Container Commercial Invoice - 2026-03-14 - invoice.pdf": what it belongs to, what it is and its
           date, then the name it was uploaded with - so a folder of downloads explains itself and sorts by reference. */
        var type = string.IsNullOrWhiteSpace(row.TypeCategory)
            ? "Other"
            : string.IsNullOrWhiteSpace(row.TypeSubType) ? row.TypeCategory! : $"{row.TypeCategory} {row.TypeSubType}";
        var parts = new List<string> { row.Reference, type };
        if (!string.IsNullOrEmpty(row.DocumentDate)) parts.Add(row.DocumentDate);
        parts.Add(row.FileName);
        row.DownloadName = SafeName(string.Join(" - ", parts));
    }

    private static string SafeName(string name)
    {
        var clean = string.Concat(name.Select(c => InvalidNameChars.Contains(c) ? '_' : c)).Trim();
        return clean.Length <= 180 ? clean : clean[..120] + "…" + clean[^55..];
    }

    /// <summary>The same name twice in one ZIP: the second becomes "name (2).pdf".</summary>
    private static string Unique(string name, HashSet<string> used)
    {
        if (used.Add(name)) return name;
        var extension = Path.GetExtension(name);
        var stem = name[..^extension.Length];
        for (var n = 2; ; n++)
        {
            var candidate = $"{stem} ({n}){extension}";
            if (used.Add(candidate)) return candidate;
        }
    }

    /// <summary>
    /// "attachments_2026-01-01_to_2026-03-31_2026-10-31.zip": the range (the document dates, else the upload dates,
    /// else "all-dates") and the day of the report.
    /// </summary>
    private static string ZipName(AttachmentReportFilters filters)
    {
        static string Range(DateOnly? from, DateOnly? to)
            => $"{from?.ToString("yyyy-MM-dd") ?? "start"}_to_{to?.ToString("yyyy-MM-dd") ?? "today"}";

        var range = filters.DocumentDateFrom is not null || filters.DocumentDateTo is not null
            ? Range(filters.DocumentDateFrom, filters.DocumentDateTo)
            : filters.UploadedFrom is not null || filters.UploadedTo is not null
                ? "uploaded_" + Range(filters.UploadedFrom, filters.UploadedTo)
                : "all-dates";
        return $"attachments_{range}_{DateTime.UtcNow:yyyy-MM-dd}.zip";
    }

    private static string SizeLabel(long bytes)
        => bytes >= 1024L * 1024 * 1024 ? $"{bytes / (1024d * 1024 * 1024):0.#} GB"
            : bytes >= 1024L * 1024 ? $"{bytes / (1024d * 1024):0.#} MB"
            : $"{Math.Max(1, bytes / 1024)} KB";

    /// <summary>A temporary file removed when its stream is closed (after the response has sent it).</summary>
    private static FileStream TempFile()
        => new(Path.Combine(Path.GetTempPath(), $"attachments-{Guid.NewGuid():N}.tmp"), FileMode.CreateNew, FileAccess.ReadWrite,
            FileShare.None, 81920, FileOptions.DeleteOnClose | FileOptions.Asynchronous);
}
