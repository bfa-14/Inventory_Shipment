using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// masterdata.Brands through its stored procedures. Every method turns a business-rule THROW
/// (55000-55006) into a <c>BusinessRuleException</c>.
/// </summary>
public interface IBrandRepository
{
    /// <summary>masterdata.usp_Brand_Search - one page of brands plus the total row count.</summary>
    Task<(IReadOnlyList<Brand> Items, int TotalCount)> SearchAsync(
        BrandQuery query, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Brand_Get.</summary>
    Task<Brand?> GetByIdAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Brand_Create - returns the new id. Throws 55000 / 55001.</summary>
    Task<int> CreateAsync(Brand brand, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_Brand_Update - throws 55000 / 55001 / 55004 / 55006.
    /// A null <paramref name="rowVersion"/> skips the concurrency check.
    /// </summary>
    Task UpdateAsync(Brand brand, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Brand_SetActive - throws 55006.</summary>
    Task SetActiveAsync(int id, bool isActive, int? userId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Brand_Delete - throws 55003 (referenced) / 55006.</summary>
    Task DeleteAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_Brand_Lookup - the brands a Brand dropdown offers.
    /// <paramref name="includeId"/> keeps one extra brand in the list even when it is inactive, so an
    /// edit form can still show the brand the record currently points at.
    /// </summary>
    Task<IReadOnlyList<BrandLookup>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);
}
