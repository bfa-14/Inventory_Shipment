using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Model.Enums;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// masterdata.Parties through its stored procedures. Every method turns a business-rule THROW
/// (60000-60008) into a <c>BusinessRuleException</c>.
/// </summary>
public interface IPartyRepository
{
    /// <summary>masterdata.usp_Party_Search - one page of parties plus the total row count.</summary>
    Task<(IReadOnlyList<Party> Items, int TotalCount)> SearchAsync(
        PartyQuery query, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Party_Get.</summary>
    Task<Party?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_Party_Lookup - the parties a typed dropdown offers. A null
    /// <paramref name="partyType"/> returns parties of every type; <paramref name="includeId"/> keeps
    /// one extra party in the list even when it is inactive or of another type, so an edit form can
    /// still show the party the record currently points at.
    /// </summary>
    Task<IReadOnlyList<PartyLookup>> LookupAsync(
        PartyType? partyType, string? search, bool activeOnly, int? includeId, int top,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_Party_NextCode - the code suggested for a new party of that type
    /// (SUP-0001, CLI-0001...). Throws 60000 when the type is not one of the four.
    /// </summary>
    Task<string> NextCodeAsync(PartyType partyType, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Party_Create - returns the new id. Throws 60000 / 60001 / 60002 / 60008.</summary>
    Task<int> CreateAsync(Party party, int? actorUserId, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_Party_Update - throws 60000 / 60001 / 60002 / 60004 / 60005 / 60006 / 60008.
    /// A null <paramref name="rowVersion"/> skips the concurrency check.
    /// </summary>
    Task UpdateAsync(
        Party party, byte[]? rowVersion, int? actorUserId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Party_SetActive - throws 60006.</summary>
    Task SetActiveAsync(int id, bool isActive, int? actorUserId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Party_Delete - throws 60003 (referenced) / 60006.</summary>
    Task DeleteAsync(int id, CancellationToken cancellationToken = default);
}
