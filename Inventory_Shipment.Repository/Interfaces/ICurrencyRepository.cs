using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// masterdata.Currencies through its stored procedures. Every method turns a business-rule THROW
/// (53000-53006) into a <c>BusinessRuleException</c>.
/// </summary>
public interface ICurrencyRepository
{
    /// <summary>masterdata.usp_Currency_Search - one page of currencies plus the total row count.</summary>
    Task<(IReadOnlyList<Currency> Items, int TotalCount)> SearchAsync(
        CurrencyQuery query, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Currency_Get.</summary>
    Task<Currency?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Currency_GetBase - the active base currency, or null when there is none.</summary>
    Task<Currency?> GetBaseAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_Currency_Lookup - the currencies a dropdown offers, base currency first.
    /// <paramref name="includeId"/> keeps one extra currency in the list even when it is inactive, so an
    /// edit form can still show the currency the record currently points at.
    /// </summary>
    Task<IReadOnlyList<CurrencyLookup>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Currency_Create - returns the new id. Throws 53000 / 53001 / 53002 / 53005.</summary>
    Task<int> CreateAsync(
        Currency currency, bool replaceBaseCurrency, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_Currency_Update - throws 53000 / 53001 / 53002 / 53004 / 53005 / 53006.
    /// A null <paramref name="rowVersion"/> skips the concurrency check.
    /// </summary>
    Task UpdateAsync(
        Currency currency, bool replaceBaseCurrency, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Currency_SetActive - throws 53005 (base currency) / 53006.</summary>
    Task SetActiveAsync(int id, bool isActive, int? userId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_Currency_Delete - throws 53003 (referenced) / 53005 (base currency) / 53006.</summary>
    Task DeleteAsync(int id, CancellationToken cancellationToken = default);
}
