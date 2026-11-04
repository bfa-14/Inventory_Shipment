using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Reports;

namespace Inventory_Shipment.Service.Interfaces;

public interface IContainerChargeReportService
{
    Task<Result<ContainerChargeReportOptions>> OptionsAsync(
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ContainerChargeReportResult>> ReportAsync(
        ContainerChargeReportQuery query, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        ContainerChargeReportQuery query, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);
}
