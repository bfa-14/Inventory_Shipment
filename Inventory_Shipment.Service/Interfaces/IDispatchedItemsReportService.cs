using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Reports;

namespace Inventory_Shipment.Service.Interfaces;

public interface IDispatchedItemsReportService
{
    Task<Result<DispatchedItemsReportResult>> ReportAsync(
        DispatchedItemsReportQuery query, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        DispatchedItemsReportQuery query, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);
}
