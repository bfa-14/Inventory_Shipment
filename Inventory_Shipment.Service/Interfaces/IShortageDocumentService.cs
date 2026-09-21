using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory.Shortages;
using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Shortage plans: the live calculation, the saved drafts and the posted snapshots. Every action
/// checks its own permission here as well as on the controller, so the rule holds for any caller.
/// </summary>
public interface IShortageDocumentService
{
    Task<Result<IReadOnlyList<ShortageLiveRowDto>>> CalculateAsync(
        ShortageCalculateQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<PagedResult<ShortageDocumentListDto>>> SearchAsync(
        ShortageDocumentQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ShortageDocumentDto>> GetAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null) or replaces a draft; the figures are the live ones at that moment.</summary>
    Task<Result<ShortageDocumentDto>> SaveDraftAsync(
        int? id, SaveShortageDocumentRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<ShortageDocumentDto>> RecalculateAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ShortageDocumentDto>> PostAsync(
        int id, string? rowVersion, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(
        int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The new purchase order draft. Needs purchase.orders.create AND sight of the plan.</summary>
    Task<Result<PurchaseDocumentDto>> CreatePurchaseOrderAsync(
        int id, CreatePurchaseOrderFromShortageRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>The saved plan as a workbook: header block, every snapshot column, totals.</summary>
    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The live rows as a workbook.</summary>
    Task<Result<(byte[] Content, string FileName)>> ExportLiveAsync(
        ShortageCalculateQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
