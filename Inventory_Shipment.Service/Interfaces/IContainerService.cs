using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Repository.Interfaces;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Containers: the import shipment between the purchase invoice and the warehouse.
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

    /// <summary>A route event: it moves the dates, the derived status and the current location. Needs containers.create.</summary>
    Task<Result<ContainerDto>> AddEventAsync(
        int id, AddEventRequest request, int userId, IReadOnlySet<string> permissions,
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

    Task<Result<ContainerDto>> CancelAsync(
        int id, CancelRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result> DeleteAsync(int id, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>Purchase invoices with something left to load. Needs containers.create.</summary>
    Task<Result<IReadOnlyList<AvailableInvoiceDto>>> GetAvailableInvoicesAsync(
        AvailableInvoiceQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The loading grid of one invoice. Needs containers.create.</summary>
    Task<Result<IReadOnlyList<AvailableInvoiceLineDto>>> GetInvoiceLinesAsync(
        int invoiceId, int? containerId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<(byte[] Content, string FileName)>> ExportAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<int>> AddFileAsync(
        int id, ContainerFileUpload upload, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<ContainerFileContent>> GetFileAsync(
        int fileId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result> DeleteFileAsync(
        int fileId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
