using Inventory_Shipment.Model.DTOs.Receipts;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>masterdata.PaymentMethods. Every write throws a <c>BusinessRuleException</c> numbered 71xxx.</summary>
public interface IPaymentMethodRepository
{
    Task<(IReadOnlyList<PaymentMethodDto> Items, int TotalCount)> SearchAsync(
        PaymentMethodQuery query, CancellationToken cancellationToken = default);

    Task<PaymentMethodDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary><paramref name="includeId"/> keeps a deactivated method visible on a receipt line that uses it.</summary>
    Task<IReadOnlyList<PaymentMethodLookupDto>> LookupAsync(
        bool activeOnly = true, int? includeId = null, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null) or updates; returns the id.</summary>
    Task<int> SaveAsync(SavePaymentMethodRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    Task SetActiveAsync(int id, bool isActive, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Only a method no receipt line uses; otherwise 71014.</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);
}
