using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;

namespace Inventory_Shipment.Service.Interfaces;

public interface ICurrencyService
{
    Task<Result<PagedResult<CurrencyDto>>> SearchAsync(CurrencyQuery query, CancellationToken cancellationToken = default);

    Task<Result<CurrencyDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>The active base currency, or NotFound when no currency carries the flag.</summary>
    Task<Result<CurrencyDto>> GetBaseAsync(CancellationToken cancellationToken = default);

    Task<Result<CurrencyDto>> CreateAsync(SaveCurrencyRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<CurrencyDto>> UpdateAsync(int id, SaveCurrencyRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<CurrencyDto>> SetActiveAsync(int id, bool isActive, int userId, CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Currencies for a dropdown; <paramref name="includeId"/> keeps one inactive currency visible.</summary>
    Task<Result<IReadOnlyList<CurrencyLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default);
}
