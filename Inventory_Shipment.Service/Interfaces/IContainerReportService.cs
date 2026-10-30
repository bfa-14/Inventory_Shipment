using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Service.Interfaces;

public interface IContainerReportService
{
    Task<Result<ContainerReportResult>> ReportAsync(
        ContainerReportQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        ContainerReportQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
