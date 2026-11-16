using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Reports;

namespace Inventory_Shipment.Service.Interfaces;

public interface IGoodsOnOrderReportService
{
    Task<Result<GoodsOnOrderReportResult>> ReportAsync(
        GoodsOnOrderReportQuery query, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        GoodsOnOrderReportQuery query, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);
}
