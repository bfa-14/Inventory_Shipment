using Inventory_Shipment.Model.DTOs.Security;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Repository.Interfaces;

public interface ILoginAuditRepository
{
    Task AddAsync(LoginAudit entry, CancellationToken cancellationToken = default);

    /// <summary>Newest attempts first, filtered by the query and capped at its Take value.</summary>
    Task<IReadOnlyList<LoginAudit>> QueryAsync(LoginAuditQuery query, CancellationToken cancellationToken = default);
}
