using Inventory_Shipment.Model.DTOs.Reports;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>The Attachment Report (script 101): reporting.usp_AttachmentReport_*.</summary>
public interface IAttachmentReportRepository
{
    /// <summary>One page of the files of <paramref name="kinds"/> matching the filters, and the count and size of them all.</summary>
    Task<(IReadOnlyList<AttachmentReportRowDto> Rows, int TotalCount, long TotalBytes)> ListAsync(
        AttachmentReportQuery query, IReadOnlyCollection<string> kinds, CancellationToken cancellationToken = default);

    /// <summary>The files a download takes, without their content: the chosen keys, or (keys null) every match.</summary>
    Task<IReadOnlyList<AttachmentReportRowDto>> FilesAsync(
        AttachmentReportFilters filters, IReadOnlyCollection<string>? keys, IReadOnlyCollection<string> kinds,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Hands each file's content to <paramref name="write"/> as a stream, one file at a time, in key order: a ZIP of
    /// 2 GB is never held in memory.
    /// </summary>
    Task ReadContentsAsync(
        IReadOnlyCollection<string> keys, Func<string, Stream, Task> write, CancellationToken cancellationToken = default);

    Task LogDownloadAsync(
        int userId, string mode, int fileCount, long totalBytes, string? criteria, CancellationToken cancellationToken = default);

    /// <summary>Every attachment type (inactive ones too: old files keep theirs).</summary>
    Task<IReadOnlyList<AttachmentReportTypeDto>> TypesAsync(CancellationToken cancellationToken = default);
}
