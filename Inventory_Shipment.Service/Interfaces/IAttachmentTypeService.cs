using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Attachment types for the container pages. Writes need the manage permission (checked here and on the
/// controller); the lookup is open to any signed-in user because every container page reads it.
/// </summary>
public interface IAttachmentTypeService
{
    /// <summary>The list page needs the manage permission; with a document kind it is what an upload dialog offers, open to anyone signed in.</summary>
    Task<Result<PagedResult<AttachmentTypeDto>>> SearchAsync(
        AttachmentTypeQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<AttachmentTypeDto>> GetAsync(int id, CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<AttachmentTypeLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, string? appliesTo = null, string? documentKind = null,
        CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<AttachmentDocumentKindDto>>> GetDocumentKindsAsync(CancellationToken cancellationToken = default);

    Task<Result<AttachmentTypeDto>> SaveAsync(
        int? id, SaveAttachmentTypeRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<AttachmentTypeDto>> SetActiveAsync(
        int id, SetLogisticsMasterActiveRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Only a row nothing uses; otherwise IN_USE (409), and the page offers to deactivate it instead.</summary>
    Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
