using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// Containers over the logistics.usp_Container_* procedures. Every write throws a
/// <c>BusinessRuleException</c> numbered 69xxx / 70xxx; the message is the procedure's.
/// </summary>
public interface IContainerRepository
{
    Task<(IReadOnlyList<ContainerListDto> Items, int TotalCount)> SearchAsync(
        ContainerQuery query, CancellationToken cancellationToken = default);

    /// <summary>The eight result sets of logistics.usp_Container_Get in one round trip; null when there is no such container.</summary>
    Task<ContainerDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Id, reference and status: what the service needs to decide before acting.</summary>
    Task<ContainerStub?> GetStubAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Creates (id null, the reference is assigned now) or updates; returns the id.</summary>
    Task<int> SaveAsync(SaveContainerRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    Task ConfirmAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Stock in at the real cost (FOB of the posted invoices + posted charges). An empty line list = everything received as loaded.</summary>
    Task OffloadAsync(int id, OffloadRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task CancelOffloadAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task CloseAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Closed → offloaded again.</summary>
    Task ReopenAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Drafts only (69005 otherwise).</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);

    /// <summary>Approved order lines that can still be loaded.</summary>
    Task<IReadOnlyList<AvailablePoLineDto>> GetAvailablePoLinesAsync(
        AvailablePoLineQuery query, CancellationToken cancellationToken = default);

    /// <summary>Container lines that can still be invoiced, by order or by container.</summary>
    Task<IReadOnlyList<InvoiceCandidateDto>> GetInvoiceCandidatesAsync(
        InvoiceCandidateQuery query, CancellationToken cancellationToken = default);

    /// <summary>The tracking board: the containers and their route legs (logistics.usp_Container_Tracking).</summary>
    Task<TrackingDto> GetTrackingAsync(TrackingQuery query, CancellationToken cancellationToken = default);

    /// <summary>One upload for one or several containers: the file stored once, one record per container.</summary>
    Task<IReadOnlyList<ContainerAttachmentCreatedDto>> AddAttachmentAsync(
        ContainerAttachmentUpload upload, int userId, CancellationToken cancellationToken = default);

    Task<ContainerAttachmentFile?> GetAttachmentFileAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>One record, or (allShared) the file from every container holding it.</summary>
    Task DeleteAttachmentAsync(int id, bool allShared, int userId, CancellationToken cancellationToken = default);

    /* ── many containers per order (script 28) ── */

    /// <summary>The proposed containers, their lines and the order lines (logistics.usp_Container_PlanFromOrder); nothing is saved.</summary>
    Task<AutoPlanDto> PlanFromOrderAsync(AutoPlanRequest request, CancellationToken cancellationToken = default);

    /// <summary>Creates every container of the plan in one transaction; the containers[].lines[] are flattened into the plan table.</summary>
    Task<IReadOnlyList<CreatedContainerDto>> CreateBatchAsync(
        CreateContainersFromPlanRequest request, int userId, CancellationToken cancellationToken = default);

    /// <summary>Container no. and seal no. of several containers; both written, null clears.</summary>
    Task<IReadOnlyList<ContainerNumberDto>> SetNumbersAsync(
        IReadOnlyList<ContainerNumberRequest> items, int userId, CancellationToken cancellationToken = default);

    /// <summary>Confirms the drafts among the ids (the others are returned unchanged), all or nothing.</summary>
    Task<IReadOnlyList<ContainerConfirmedDto>> ConfirmManyAsync(
        IReadOnlyList<int> ids, int userId, CancellationToken cancellationToken = default);

    /// <summary>Deletes drafts only (69005 names the first that is not), all or nothing; returns the count.</summary>
    Task<int> DeleteManyAsync(IReadOnlyList<int> ids, int userId, CancellationToken cancellationToken = default);
}

public sealed class ContainerStub
{
    public int Id { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public byte Status { get; init; }
}
