using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// Containers over the logistics.usp_Container_* procedures. Every write throws a
/// <c>BusinessRuleException</c> numbered 69xxx; the message is the procedure's.
/// </summary>
public interface IContainerRepository
{
    Task<(IReadOnlyList<ContainerListDto> Items, int TotalCount)> SearchAsync(
        ContainerQuery query, CancellationToken cancellationToken = default);

    /// <summary>The six result sets of logistics.usp_Container_Get in one round trip; null when there is no such container.</summary>
    Task<ContainerDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Id, reference and status: what the service needs to decide before acting.</summary>
    Task<ContainerStub?> GetStubAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null, the reference is assigned now) or updates; returns the id.</summary>
    Task<int> SaveAsync(SaveContainerRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    Task ConfirmAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task AddEventAsync(int id, AddEventRequest request, int userId, CancellationToken cancellationToken = default);

    /// <summary>Stock in at the invoice landed cost. An empty line list = everything received as loaded.</summary>
    Task OffloadAsync(int id, OffloadRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task CancelOffloadAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task CloseAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Drafts only (69005 otherwise).</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<AvailableInvoiceDto>> GetAvailableInvoicesAsync(
        AvailableInvoiceQuery query, CancellationToken cancellationToken = default);

    /// <summary>The lines of one purchase invoice with what containers already hold of each; null when it is not a purchase invoice.</summary>
    Task<IReadOnlyList<AvailableInvoiceLineDto>?> GetInvoiceLinesAsync(
        int invoiceId, int? containerId, CancellationToken cancellationToken = default);

    Task<int> AddFileAsync(
        int containerId, ContainerFileUpload upload, int userId, CancellationToken cancellationToken = default);

    Task<ContainerFileContent?> GetFileAsync(int fileId, CancellationToken cancellationToken = default);

    Task DeleteFileAsync(int fileId, int userId, CancellationToken cancellationToken = default);
}

public sealed class ContainerStub
{
    public int Id { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public byte Status { get; init; }
}

/// <summary>A file on its way into logistics.ContainerFiles, with the attachment type and note the page chose.</summary>
public sealed class ContainerFileUpload
{
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public byte[] Content { get; init; } = [];
    public int? AttachmentTypeId { get; init; }
    public string? Note { get; init; }
    public DateOnly? DocumentDate { get; init; }
}

public sealed class ContainerFileContent
{
    public int Id { get; init; }
    public int ContainerId { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public byte[] Content { get; init; } = [];
}
