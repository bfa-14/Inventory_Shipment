using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Reports;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>Reports › Attachment Report (script 101).</summary>
public interface IAttachmentReportService
{
    Task<Result<AttachmentReportResult>> ListAsync(
        AttachmentReportQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<AttachmentReportTypeDto>>> TypesAsync(
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>One chosen file as itself, several or all as a ZIP; logged before it is sent.</summary>
    Task<Result<AttachmentDownloadFile>> DownloadAsync(
        AttachmentDownloadRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
