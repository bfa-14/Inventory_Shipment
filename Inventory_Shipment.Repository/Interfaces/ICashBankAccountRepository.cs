using Inventory_Shipment.Model.DTOs.Receipts;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>masterdata.CashBankAccounts. Every write throws a <c>BusinessRuleException</c> numbered 71xxx.</summary>
public interface ICashBankAccountRepository
{
    Task<(IReadOnlyList<CashBankAccountDto> Items, int TotalCount)> SearchAsync(
        CashBankAccountQuery query, CancellationToken cancellationToken = default);

    Task<CashBankAccountDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>
    /// What a receipt line's account picker offers. <paramref name="currencyId"/> keeps only accounts
    /// holding the line's currency; <paramref name="branchId"/> keeps those the branch may use (an
    /// account with no branch belongs to everybody). <paramref name="includeId"/> keeps one account
    /// visible whatever the filters say, so a saved line whose account was since deactivated still
    /// resolves.
    /// </summary>
    Task<IReadOnlyList<CashBankAccountLookupDto>> LookupAsync(
        bool activeOnly = true, int? currencyId = null, int? branchId = null, int? includeId = null,
        CancellationToken cancellationToken = default);

    /// <summary>Creates (id null) or updates; returns the id.</summary>
    Task<int> SaveAsync(SaveCashBankAccountRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    Task SetActiveAsync(int id, bool isActive, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Only an account no receipt line uses; otherwise 71014.</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);
}
