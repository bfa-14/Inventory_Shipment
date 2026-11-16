using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Repository.Interfaces;

public interface IContainerReportRepository
{
    /// <summary>logistics.usp_ContainerReport: the rows, each with its charges per type, and the charge types.</summary>
    Task<(IReadOnlyList<ContainerReportRowDto> Rows, IReadOnlyList<ContainerReportChargeTypeDto> ChargeTypes)> ReportAsync(
        ContainerReportQuery query, CancellationToken cancellationToken = default);

    /// <summary>
    /// (109) The pieces per container of each item (logistics.fn_ItemPcsPerContainer: its Container unit, none when it has
    /// none or 1): Goods on Order estimates the containers of the pieces not on a container yet.
    /// </summary>
    Task<IReadOnlyDictionary<int, decimal>> PcsPerContainerAsync(IReadOnlyCollection<int> itemIds, CancellationToken cancellationToken = default);
}
