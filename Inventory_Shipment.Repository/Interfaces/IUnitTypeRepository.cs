using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// masterdata.UnitTypes through its stored procedures. Every method turns a business-rule THROW
/// (57000-57006) into a <c>BusinessRuleException</c>.
/// </summary>
public interface IUnitTypeRepository
{
    /// <summary>masterdata.usp_UnitType_Search - one page of unit types plus the total row count.</summary>
    Task<(IReadOnlyList<UnitType> Items, int TotalCount)> SearchAsync(
        UnitTypeQuery query, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_UnitType_Get.</summary>
    Task<UnitType?> GetByIdAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_UnitType_Create - returns the new id. Throws 57000 / 57001.</summary>
    Task<int> CreateAsync(UnitType unitType, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_UnitType_Update - throws 57000 / 57001 / 57004 / 57006.
    /// A null <paramref name="rowVersion"/> skips the concurrency check.
    /// </summary>
    Task UpdateAsync(UnitType unitType, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_UnitType_SetActive - throws 57006.</summary>
    Task SetActiveAsync(int id, bool isActive, int? userId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_UnitType_Delete - throws 57003 (used by item units) / 57006.</summary>
    Task DeleteAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_UnitType_Lookup - the unit types a Unit Type dropdown offers.
    /// <paramref name="includeId"/> keeps one extra unit type in the list even when it is inactive, so an
    /// edit form can still show the unit type the record currently points at.
    /// </summary>
    Task<IReadOnlyList<UnitTypeLookup>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);
}
