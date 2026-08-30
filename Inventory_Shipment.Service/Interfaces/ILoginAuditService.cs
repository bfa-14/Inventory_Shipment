using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Security;

namespace Inventory_Shipment.Service.Interfaces;

public interface ILoginAuditService
{
    Task<Result<IReadOnlyList<LoginAuditDto>>> GetAsync(LoginAuditQuery query, CancellationToken cancellationToken = default);
}
