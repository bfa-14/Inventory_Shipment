using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Containers: the import shipment between the purchase order and the warehouse — loaded from order
/// lines, invoiced from their lines, moved by shipment movements, costed by their charges.
///
/// EVERY METHOD TAKES THE CALLER'S PERMISSIONS, like the purchase documents: the controller
/// authenticates, the service decides — containers.view / create / confirm / offload / cancel /
/// close / delete, and containers.overcapacity for a save that confirms the capacity warning.
/// </summary>
public interface IContainerService
{
    Task<Result<PagedResult<ContainerListDto>>> SearchAsync(
        ContainerQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<ContainerDto>> GetAsync(int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null) or updates. allowOverCapacity = true needs containers.overcapacity (403 otherwise).</summary>
    Task<Result<ContainerDto>> SaveAsync(
        int? id, SaveContainerRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<ContainerDto>> ConfirmAsync(
        int id, ContainerActionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<ContainerDto>> OffloadAsync(
        int id, OffloadRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Reverses an offload. Needs containers.cancel.</summary>
    Task<Result<ContainerDto>> CancelOffloadAsync(
        int id, CancelRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<ContainerDto>> CloseAsync(
        int id, ContainerActionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Closed → offloaded again. Needs containers.close.</summary>
    Task<Result<ContainerDto>> ReopenAsync(
        int id, ContainerActionRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<ContainerDto>> CancelAsync(
        int id, CancelRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Approved order lines that can still be loaded. Needs containers.create.</summary>
    Task<Result<IReadOnlyList<AvailablePoLineDto>>> GetAvailablePoLinesAsync(
        AvailablePoLineQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Container lines still to invoice, by order or container (one of them is required). Needs containers.view.</summary>
    Task<Result<IReadOnlyList<InvoiceCandidateDto>>> GetInvoiceCandidatesAsync(
        InvoiceCandidateQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The tracking board: containers and their route legs. Needs containers.view.</summary>
    Task<Result<TrackingDto>> GetTrackingAsync(
        TrackingQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>One upload for one or several containers; the created records. Needs containers.attachments.manage.</summary>
    Task<Result<IReadOnlyList<ContainerAttachmentCreatedDto>>> AddAttachmentAsync(
        ContainerAttachmentUpload upload, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<ContainerAttachmentFile>> GetAttachmentFileAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>allShared = the details of every container holding the file. Needs containers.attachments.manage.</summary>
    Task<Result> UpdateAttachmentAsync(
        int id, bool allShared, ContainerAttachmentEdit edit, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>allShared = the file from every container holding it. Needs containers.attachments.manage.</summary>
    Task<Result> DeleteAttachmentAsync(
        int id, bool allShared, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /* ── many containers per order ── */

    /// <summary>The proposed containers of an approved order for one container type; nothing is saved. Needs containers.create.</summary>
    Task<Result<AutoPlanDto>> AutoPlanAsync(
        AutoPlanRequest request, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>
    /// Creates the (edited) plan, all or nothing. Needs containers.create; allowOverCapacity needs
    /// containers.overcapacity and confirm needs containers.confirm (403 before anything is created).
    /// </summary>
    Task<Result<IReadOnlyList<CreatedContainerDto>>> CreateFromPlanAsync(
        CreateContainersFromPlanRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Container no. and seal no. of several containers. Needs containers.create.</summary>
    Task<Result<IReadOnlyList<ContainerNumberDto>>> SetNumbersAsync(
        ContainerNumbersRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Confirms the drafts among the selected containers. Needs containers.confirm.</summary>
    Task<Result<IReadOnlyList<ContainerConfirmedDto>>> ConfirmManyAsync(
        IdsRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Deletes the selected drafts. Needs containers.delete.</summary>
    Task<Result<ContainersDeletedDto>> DeleteManyAsync(
        IdsRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
