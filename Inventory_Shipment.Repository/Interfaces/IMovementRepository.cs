using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// Shipment movements over the logistics.usp_Movement_* procedures. Every write throws a
/// <c>BusinessRuleException</c> numbered 70xxx; the message is the procedure's.
/// </summary>
public interface IMovementRepository
{
    Task<(IReadOnlyList<MovementListDto> Items, int TotalCount)> SearchAsync(
        MovementQuery query, CancellationToken cancellationToken = default);

    /// <summary>The four result sets of logistics.usp_Movement_Get; null when there is no such movement.</summary>
    Task<MovementDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null, the number MOV-yyyy-nnnnnn is assigned now) or updates; returns the id.</summary>
    Task<int> SaveAsync(SaveMovementRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    /// <summary>Start, Complete or Cancel: the containers' status, dates and location follow.</summary>
    Task SetStatusAsync(
        int id, string action, DateOnly? date, string? reason, byte[]? rowVersion, int userId,
        CancellationToken cancellationToken = default);

    /// <summary>Planned only (70005 otherwise).</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// One movement for the chosen containers (logistics.usp_Movement_ShipContainers), in one transaction; the movement row.
    /// confirmDrafts is the one the service allows, not the request's.
    /// </summary>
    Task<ShippedMovementDto> ShipContainersAsync(
        ShipContainersRequest request, bool confirmDrafts, int userId, CancellationToken cancellationToken = default);
}
