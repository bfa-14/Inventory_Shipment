using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>masterdata.Ports — sea ports, borders and inland places. Every write throws a <c>BusinessRuleException</c> numbered 69xxx.</summary>
public interface IPortRepository
{
    Task<(IReadOnlyList<PortDto> Items, int TotalCount)> SearchAsync(PortQuery query, CancellationToken cancellationToken = default);

    Task<PortDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<PortLookupDto>> LookupAsync(
        string? kind = null, bool activeOnly = true, int? includeId = null, CancellationToken cancellationToken = default);

    Task<int> SaveAsync(SavePortRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    Task SetActiveAsync(int id, bool isActive, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Only a port no container or route event uses; otherwise 69014.</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);
}
