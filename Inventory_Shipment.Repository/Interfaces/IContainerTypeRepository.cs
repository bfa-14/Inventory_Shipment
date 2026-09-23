using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>masterdata.ContainerTypes. Every write throws a <c>BusinessRuleException</c> numbered 69xxx.</summary>
public interface IContainerTypeRepository
{
    Task<(IReadOnlyList<ContainerTypeDto> Items, int TotalCount)> SearchAsync(
        ContainerTypeQuery query, CancellationToken cancellationToken = default);

    Task<ContainerTypeDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary><paramref name="includeId"/> keeps a deactivated type visible on a container that uses it.</summary>
    Task<IReadOnlyList<ContainerTypeLookupDto>> LookupAsync(
        bool activeOnly = true, int? includeId = null, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null) or updates; returns the id.</summary>
    Task<int> SaveAsync(SaveContainerTypeRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    Task SetActiveAsync(int id, bool isActive, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Only a type no container uses; otherwise 69014.</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);
}
