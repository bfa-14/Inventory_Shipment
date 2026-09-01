using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;

namespace Inventory_Shipment.Service.Interfaces;

public interface IExchangeRateService
{
    Task<Result<PagedResult<ExchangeRateDto>>> SearchAsync(ExchangeRateQuery query, CancellationToken cancellationToken = default);

    Task<Result<ExchangeRateDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>
    /// The rate in force per rate type for one currency (up to 3 rows: Official, Non-official, Market).
    /// A null <paramref name="asOfDate"/> means today (UTC).
    /// </summary>
    Task<Result<IReadOnlyList<ExchangeRateDto>>> LatestAsync(
        int currencyId, DateOnly? asOfDate, CancellationToken cancellationToken = default);

    Task<Result<ExchangeRateDto>> CreateAsync(SaveExchangeRateRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result<ExchangeRateDto>> UpdateAsync(int id, SaveExchangeRateRequest request, int userId, CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default);
}
