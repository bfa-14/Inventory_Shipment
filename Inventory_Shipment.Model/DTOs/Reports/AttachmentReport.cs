using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Reports;

/// <summary>
/// The Attachment Report's filters (script 101). Types, document dates and upload dates combine with AND; no type is
/// every type; a document-date range leaves out the files that have no document date. Every date is inclusive.
/// </summary>
public class AttachmentReportFilters
{
    /// <summary>Attachment type ids; empty = every type.</summary>
    public int[]? TypeIds { get; init; }

    /// <summary>The date typed on the file (the document's own date).</summary>
    public DateOnly? DocumentDateFrom { get; init; }
    public DateOnly? DocumentDateTo { get; init; }

    /// <summary>The day the file was added to the system (UTC).</summary>
    public DateOnly? UploadedFrom { get; init; }
    public DateOnly? UploadedTo { get; init; }
}

public sealed class AttachmentReportQuery : AttachmentReportFilters
{
    [Range(1, int.MaxValue)]
    public int Page { get; init; } = 1;

    [Range(1, 200)]
    public int PageSize { get; init; } = 50;
}

/// <summary>One attachment of the report.</summary>
public sealed class AttachmentReportRowDto
{
    /// <summary>"CNT:12": what a download names this file by.</summary>
    public string Key { get; set; } = string.Empty;
    public string Source { get; set; } = string.Empty;
    public int Id { get; set; }

    /// <summary>The document type code (PO, PINV, GRN, CONTAINER, ITEM, ...) and what it is called.</summary>
    public string DocumentKind { get; set; } = string.Empty;
    public string DocumentKindName { get; set; } = string.Empty;

    /// <summary>The container, document or item the file belongs to, and the page that opens it.</summary>
    public int OwnerId { get; set; }
    public string Reference { get; set; } = string.Empty;
    public string? OwnerPath { get; set; }

    public int? AttachmentTypeId { get; set; }
    public string? TypeCategory { get; set; }
    public string? TypeSubType { get; set; }
    /// <summary>"Container › Commercial Invoice", or "Other" for a file filed before attachment types existed.</summary>
    public string TypeLabel { get; set; } = string.Empty;

    public string FileName { get; set; } = string.Empty;
    public string ContentType { get; set; } = string.Empty;
    public long SizeBytes { get; set; }
    public string? DocumentDate { get; set; }
    public DateTime UploadedAtUtc { get; set; }
    public string? UploadedByName { get; set; }

    /// <summary>"KTG-2026-0031 - Container Commercial Invoice - 2026-03-14 - invoice.pdf": the name it is downloaded under.</summary>
    public string DownloadName { get; set; } = string.Empty;
}

public sealed class AttachmentReportResult
{
    public IReadOnlyList<AttachmentReportRowDto> Items { get; init; } = [];
    public int TotalCount { get; init; }
    public long TotalBytes { get; init; }
    public int Page { get; init; }
    public int PageSize { get; init; }

    /// <summary>The download limits (Reports:AttachmentZipMaxFiles / MaxBytes): the page warns before asking.</summary>
    public int MaxFiles { get; init; }
    public long MaxBytes { get; init; }

    /// <summary>What "Download all" names its ZIP for these filters.</summary>
    public string ZipFileName { get; init; } = string.Empty;
}

/// <summary>An attachment type the filter offers.</summary>
public sealed class AttachmentReportTypeDto
{
    public int Id { get; init; }
    public string Category { get; init; } = string.Empty;
    public string SubType { get; init; } = string.Empty;
    public bool IsActive { get; init; }
}

/// <summary>
/// A download: the chosen <see cref="Keys"/> (one file comes back as itself, several as a ZIP), or <see cref="All"/>
/// the files matching the filters (always a ZIP).
/// </summary>
public sealed class AttachmentDownloadRequest : AttachmentReportFilters
{
    [MaxLength(5000)]
    public string[]? Keys { get; init; }

    public bool All { get; init; }
}

/// <summary>A download ready to send: written to a temporary file the stream deletes when it is closed.</summary>
public sealed class AttachmentDownloadFile
{
    public required Stream Content { get; init; }
    public required string FileName { get; init; }
    public required string ContentType { get; init; }
}
