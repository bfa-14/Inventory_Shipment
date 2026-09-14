using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// masterdata.PriceLists through its stored procedures. Every method turns a business-rule THROW
/// (58000-58009) into a <c>BusinessRuleException</c>.
/// </summary>
public interface IPriceListRepository
{
    /// <summary>masterdata.usp_PriceList_Search - one page of price lists plus the total row count.</summary>
    Task<(IReadOnlyList<PriceList> Items, int TotalCount)> SearchAsync(
        PriceListQuery query, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_PriceList_Get.</summary>
    Task<PriceList?> GetByIdAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_PriceList_Create - returns the new id. Throws 58000 / 58001 / 58008.</summary>
    Task<int> CreateAsync(PriceList priceList, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_PriceList_Update - throws 58000 / 58001 / 58004 / 58006 / 58008 / 58009.
    /// A null <paramref name="rowVersion"/> skips the concurrency check.
    /// </summary>
    Task UpdateAsync(PriceList priceList, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_PriceList_SetActive - throws 58006.</summary>
    Task SetActiveAsync(int id, bool isActive, int? userId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_PriceList_Delete - throws 58003 (holds prices / referenced) / 58006.</summary>
    Task DeleteAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_PriceList_Lookup - the price lists a Price List dropdown offers.
    /// <paramref name="includeId"/> keeps one extra list in the result even when it is inactive, so an
    /// edit form can still show the list the record currently points at.
    /// </summary>
    Task<IReadOnlyList<PriceListLookup>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_UnitPrice_Resolve - the price of one unit in one list, the branch price
    /// winning over the All Branches price. Null when the list has none for the unit.
    /// </summary>
    Task<UnitPriceResolutionDto?> ResolveUnitPriceAsync(
        int itemUnitId, int priceListId, int? branchId, CancellationToken cancellationToken = default);
}
