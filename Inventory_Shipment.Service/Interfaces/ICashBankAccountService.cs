using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Receipts;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Cash and bank accounts for the receipt page. Writes need the manage permission (checked here and
/// on the controller); the lookup is open to any signed-in user because the receipt page reads it.
/// </summary>
public interface ICashBankAccountService
{
    Task<Result<PagedResult<CashBankAccountDto>>> SearchAsync(CashBankAccountQuery query, CancellationToken cancellationToken = default);

    Task<Result<CashBankAccountDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>The accounts a receipt line may use: of its currency, and open to its branch.</summary>
    Task<Result<IReadOnlyList<CashBankAccountLookupDto>>> LookupAsync(
        bool activeOnly, int? currencyId, int? branchId, int? includeId, CancellationToken cancellationToken = default);

    Task<Result<CashBankAccountDto>> SaveAsync(
        int? id, SaveCashBankAccountRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<CashBankAccountDto>> SetActiveAsync(
        int id, SetReceiptMasterActiveRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Only an account nothing uses; otherwise IN_USE (409), and the page offers to deactivate it instead.</summary>
    Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
