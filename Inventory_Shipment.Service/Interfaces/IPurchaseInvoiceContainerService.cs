using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// A purchase invoice "shipped in containers" (script 43): its containers, read, linked, unlinked and added from the
/// invoice. Reading needs purchase.invoices.view; linking and unlinking the invoice edit permission
/// (purchase.invoices.create); adding containers that and containers.create.
/// </summary>
public interface IPurchaseInvoiceContainerService
{
    /// <summary>
    /// Any purchase invoice: its items and containers, and the state - what it can do with containers and why not, the
    /// caller's permissions included (rule 9). Never refused because of the rules: the state carries the reason.
    /// </summary>
    Task<Result<InvoiceContainerSummaryDto>> GetSummaryAsync(
        int invoiceId, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<IReadOnlyList<InvoiceLinkCandidateDto>>> GetCandidatesAsync(
        int invoiceId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    Task<Result<InvoiceContainerSummaryDto>> LinkAsync(
        int invoiceId, LinkInvoiceContainersRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    Task<Result<InvoiceContainerSummaryDto>> UnlinkAsync(
        int invoiceId, int containerId, string? rowVersion, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>A container on the invoice's order with the given pieces of the invoice, linked in the same transaction.</summary>
    Task<Result<InvoiceContainersCreatedDto>> AddContainerAsync(
        int invoiceId, AddInvoiceContainerRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>The order's auto-plan proposal for what the invoice has outside containers. Nothing is saved.</summary>
    Task<Result<AutoPlanDto>> AutoPlanAsync(
        int invoiceId, InvoiceAutoPlanRequest request, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>The proposal created on the invoice's order and linked to the invoice, in one transaction.</summary>
    Task<Result<InvoiceContainersCreatedDto>> CreateFromPlanAsync(
        int invoiceId, InvoiceContainersFromPlanRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);
}
