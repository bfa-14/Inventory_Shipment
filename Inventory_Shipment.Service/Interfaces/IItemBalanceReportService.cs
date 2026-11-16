using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Reports;

namespace Inventory_Shipment.Service.Interfaces;

public interface IItemBalanceReportService
{
    Task<Result<IReadOnlyList<ItemBalanceWarehouseDto>>> WarehousesAsync(
        int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The report; <paramref name="output"/> (Screen | Print) is what the run log records.</summary>
    Task<Result<ItemBalanceReportResult>> ReportAsync(
        ItemBalanceReportQuery query, string output, int userId, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        ItemBalanceReportQuery query, int userId, string userName, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<ItemBalanceMovementsResult>> MovementsAsync(
        ItemBalanceMovementsQuery query, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
