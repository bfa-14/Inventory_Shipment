using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Enums;

namespace Inventory_Shipment.Service.Interfaces;

public interface IPartyService
{
    Task<Result<PagedResult<PartyDto>>> SearchAsync(PartyQuery query, CancellationToken cancellationToken = default);

    Task<Result<PartyDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    Task<Result<PartyDto>> CreateAsync(SavePartyRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<PartyDto>> UpdateAsync(int id, SavePartyRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<PartyDto>> SetActiveAsync(int id, bool isActive, int userId, CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>
    /// Parties for a typed dropdown - the suppliers on a purchase order, the clients on an invoice.
    /// A null <paramref name="partyType"/> offers parties of every type; <paramref name="includeId"/>
    /// keeps one party visible even when it is inactive or of another type.
    /// </summary>
    Task<Result<IReadOnlyList<PartyLookupDto>>> LookupAsync(
        PartyType? partyType, string? search, bool activeOnly, int? includeId, int top,
        CancellationToken cancellationToken = default);

    /// <summary>The code suggested for a new party of that type (SUP-0001, CLI-0001...).</summary>
    Task<Result<NextCodeDto>> NextCodeAsync(PartyType partyType, CancellationToken cancellationToken = default);
}
