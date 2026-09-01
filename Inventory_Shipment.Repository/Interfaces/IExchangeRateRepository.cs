using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// masterdata.ExchangeRates through its stored procedures. Every method turns a business-rule THROW
/// (53000 / 53004 / 53005 / 53006 / 53007 / 53008) into a <c>BusinessRuleException</c>.
/// </summary>
public interface IExchangeRateRepository
{
    /// <summary>masterdata.usp_ExchangeRate_Search - one page of rates (joined with the currency) plus the total.</summary>
    Task<(IReadOnlyList<ExchangeRate> Items, int TotalCount)> SearchAsync(
        ExchangeRateQuery query, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_ExchangeRate_Get.</summary>
    Task<ExchangeRate?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_ExchangeRate_GetLatest - the rate in force per rate type (up to 3 rows) for one
    /// currency. A null <paramref name="asOfDate"/> means today (UTC).
    /// </summary>
    Task<IReadOnlyList<ExchangeRate>> GetLatestAsync(
        int currencyId, DateOnly? asOfDate, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_ExchangeRate_Create - returns the new id. Throws 53000 / 53005 / 53006 / 53007 / 53008.</summary>
    Task<int> CreateAsync(ExchangeRate rate, int? userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// masterdata.usp_ExchangeRate_Update - throws 53000 / 53004 / 53005 / 53006 / 53007.
    /// A null <paramref name="rowVersion"/> skips the concurrency check.
    /// </summary>
    Task UpdateAsync(
        ExchangeRate rate, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default);

    /// <summary>masterdata.usp_ExchangeRate_Delete - throws 53006.</summary>
    Task DeleteAsync(int id, CancellationToken cancellationToken = default);
}
