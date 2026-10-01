using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>masterdata.AttachmentTypes (category / sub type). Every write throws a <c>BusinessRuleException</c> numbered 69xxx.</summary>
public interface IAttachmentTypeRepository
{
    Task<(IReadOnlyList<AttachmentTypeDto> Items, int TotalCount)> SearchAsync(
        AttachmentTypeQuery query, CancellationToken cancellationToken = default);

    Task<AttachmentTypeDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<AttachmentTypeLookupDto>> LookupAsync(
        bool activeOnly = true, int? includeId = null, string? appliesTo = null, CancellationToken cancellationToken = default);

    Task<int> SaveAsync(SaveAttachmentTypeRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    Task SetActiveAsync(int id, bool isActive, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Only a type no container file uses; otherwise 69014.</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);
}
