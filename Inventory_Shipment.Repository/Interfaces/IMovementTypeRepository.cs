using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>masterdata.MovementTypes — the legs a container's route is made of. Every write throws a <c>BusinessRuleException</c> numbered 70xxx.</summary>
public interface IMovementTypeRepository
{
    Task<(IReadOnlyList<MovementTypeDto> Items, int TotalCount)> SearchAsync(
        MovementTypeQuery query, CancellationToken cancellationToken = default);

    Task<MovementTypeDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<MovementTypeLookupDto>> LookupAsync(
        bool activeOnly = true, int? includeId = null, CancellationToken cancellationToken = default);

    Task<int> SaveAsync(SaveMovementTypeRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    Task SetActiveAsync(int id, bool isActive, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Only a type no movement uses; otherwise 70014.</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);
}
