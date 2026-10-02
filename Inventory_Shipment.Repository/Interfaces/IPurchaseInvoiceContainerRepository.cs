using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// A purchase invoice and its containers (script 43). Every write throws a <c>BusinessRuleException</c>: 65xxx from the
/// invoice procedures, 69xxx / 70xxx from the container procedures when containers are created from the invoice.
/// </summary>
public interface IPurchaseInvoiceContainerRepository
{
    Task<InvoiceContainerSummaryDto> GetSummaryAsync(int invoiceId, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<InvoiceLinkCandidateDto>> GetCandidatesAsync(int invoiceId, CancellationToken cancellationToken = default);

    Task<InvoiceContainerSummaryDto> LinkAsync(
        int invoiceId, IReadOnlyList<ContainerLineQuantityRequest> links, byte[]? rowVersion, int userId,
        CancellationToken cancellationToken = default);

    Task<InvoiceContainerSummaryDto> UnlinkAsync(
        int invoiceId, int containerId, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>One container on the invoice's order (usp_Container_Save) and every line of it linked, in ONE transaction.</summary>
    Task<InvoiceContainersCreatedDto> AddContainerAsync(
        int invoiceId, SaveContainerRequest container, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>The containers of a plan on the invoice's order (usp_Container_CreateBatch) and all linked, in ONE transaction.</summary>
    Task<InvoiceContainersCreatedDto> CreateFromPlanAsync(
        int invoiceId, CreateContainersFromPlanRequest plan, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);
}
