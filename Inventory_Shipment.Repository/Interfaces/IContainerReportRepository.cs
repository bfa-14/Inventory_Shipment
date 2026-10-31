using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Repository.Interfaces;

public interface IContainerReportRepository
{
    /// <summary>logistics.usp_ContainerReport: the rows, each with its charges per type, and the charge types.</summary>
    Task<(IReadOnlyList<ContainerReportRowDto> Rows, IReadOnlyList<ContainerReportChargeTypeDto> ChargeTypes)> ReportAsync(
        ContainerReportQuery query, CancellationToken cancellationToken = default);
}
