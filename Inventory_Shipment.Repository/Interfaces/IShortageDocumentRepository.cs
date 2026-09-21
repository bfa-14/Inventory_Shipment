using Inventory_Shipment.Model.DTOs.Inventory.Shortages;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// Shortage planning documents (script 22): the live calculation a draft is loaded from, and the
/// saved plans. Every write throws a <c>BusinessRuleException</c> numbered 66xxx.
/// </summary>
public interface IShortageDocumentRepository
{
    /// <summary>inventory.usp_Shortage_Calculate — the LIVE rows of one warehouse. Not paged: the page picks from them.</summary>
    Task<IReadOnlyList<ShortageLiveRowDto>> CalculateAsync(ShortageCalculateQuery query, CancellationToken cancellationToken = default);

    Task<(IReadOnlyList<ShortageDocumentListDto> Items, int TotalCount)> SearchAsync(
        ShortageDocumentQuery query, CancellationToken cancellationToken = default);

    /// <summary>Header, lines, purchase orders and audit in one round trip; null when there is no such plan.</summary>
    Task<ShortageDocumentDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null — the number is assigned now) or replaces a draft. The procedure takes the live figures itself. Returns the id.</summary>
    Task<int> SaveAsync(SaveShortageDocumentRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    /// <summary>Draft only: the live figures again, what was typed kept.</summary>
    Task RecalculateAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task PostAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Drafts only.</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);

    /// <summary>Posted only: one draft purchase order from the lines with a required quantity; the new order's id.</summary>
    Task<int> CreatePurchaseOrderAsync(
        int id, DateOnly? documentDate, DateOnly? expectedDate, int userId, CancellationToken cancellationToken = default);
}
