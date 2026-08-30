using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Security;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;

namespace Inventory_Shipment.Service.Implementations;

public sealed class LoginAuditService : ILoginAuditService
{
    private readonly ILoginAuditRepository _loginAudit;

    public LoginAuditService(ILoginAuditRepository loginAudit)
    {
        _loginAudit = loginAudit;
    }

    public async Task<Result<IReadOnlyList<LoginAuditDto>>> GetAsync(LoginAuditQuery query, CancellationToken cancellationToken = default)
    {
        var entries = await _loginAudit.QueryAsync(query, cancellationToken);

        var dtos = entries.Select(e => new LoginAuditDto
        {
            Id = e.Id,
            Username = e.Username,
            UserId = e.UserId,
            Succeeded = e.Succeeded,
            FailureReason = e.FailureReason,
            IpAddress = e.IpAddress,
            UserAgent = e.UserAgent,
            AttemptedAtUtc = e.AttemptedAtUtc.AsUtc()
        }).ToList();

        return Result<IReadOnlyList<LoginAuditDto>>.Success(dtos);
    }
}
