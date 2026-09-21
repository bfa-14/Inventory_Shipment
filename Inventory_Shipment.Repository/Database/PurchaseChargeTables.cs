using System.Data;
using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Repository.Database;

/// <summary>
/// The two table-valued parameters that carry charges into SQL, built once for the two callers that
/// send them: a draft invoice's Charges tab and a landed cost adjustment.
///
/// COLUMN ORDER IS THE TYPE'S ORDER AND IS LOAD-BEARING — a table-valued parameter is sent
/// positionally, so a column moved here is silently read as another one on the server. Types are
/// declared rather than inferred: an all-null column infers as string and the batch is refused.
/// NULLS MEAN SOMETHING HERE ("the document's currency", "the type's method", "the date's rate"),
/// so they are sent as nulls and never flattened to a zero or an empty string.
/// </summary>
public static class PurchaseChargeTables
{
    public const string ChargeTypeName = "purchase.tvp_PurchaseCharge";
    public const string ManualAllocationTypeName = "purchase.tvp_ManualAllocation";

    /// <summary>Shaped like purchase.tvp_PurchaseCharge. Lines are numbered from their position, one authority.</summary>
    public static DataTable Charges(IReadOnlyList<PurchaseChargeRequest> charges)
    {
        var table = new DataTable();
        table.Columns.Add("LineNumber", typeof(int));
        table.Columns.Add("ChargeTypeId", typeof(int));
        table.Columns.Add("Description", typeof(string));
        table.Columns.Add("ProviderPartyId", typeof(int));
        table.Columns.Add("Reference", typeof(string));
        table.Columns.Add("CurrencyId", typeof(int));
        table.Columns.Add("RateType", typeof(byte));
        table.Columns.Add("ExchangeRate", typeof(decimal));
        table.Columns.Add("Amount", typeof(decimal));
        table.Columns.Add("AllocationMethod", typeof(string));
        table.Columns.Add("IncludedInSupplierInvoice", typeof(bool));
        table.Columns.Add("Notes", typeof(string));

        foreach (var charge in charges)
        {
            table.Rows.Add(
                charge.LineNumber,
                charge.ChargeTypeId,
                (object?)charge.Description ?? DBNull.Value,
                (object?)charge.ProviderPartyId ?? DBNull.Value,
                (object?)charge.Reference ?? DBNull.Value,
                (object?)charge.CurrencyId ?? DBNull.Value,
                (object?)charge.RateType ?? DBNull.Value,
                (object?)charge.ExchangeRate ?? DBNull.Value,
                charge.Amount,
                (object?)ChargeAllocationMethods.Normalize(charge.AllocationMethod) ?? DBNull.Value,
                charge.IncludedInSupplierInvoice,
                (object?)charge.Notes ?? DBNull.Value);
        }

        return table;
    }

    /// <summary>
    /// Shaped like purchase.tvp_ManualAllocation. Only the allocations of charges that are still in
    /// the list survive: a charge removed on screen takes its cells with it, and the server would
    /// otherwise refuse the whole save for an allocation pointing at a charge that no longer exists.
    /// </summary>
    public static DataTable ManualAllocations(
        IReadOnlyList<ManualAllocationRequest> allocations, IReadOnlyList<PurchaseChargeRequest> charges)
    {
        var table = new DataTable();
        table.Columns.Add("ChargeLineNumber", typeof(int));
        table.Columns.Add("PurchaseLineId", typeof(int));
        table.Columns.Add("AmountBase", typeof(decimal));

        var manualLines = charges
            .Where(c => string.Equals(
                ChargeAllocationMethods.Normalize(c.AllocationMethod), ChargeAllocationMethods.Manual, StringComparison.Ordinal))
            .Select(c => c.LineNumber)
            .ToHashSet();

        // A charge with no method of its own inherits the type's, which may also be Manual — the
        // server resolves that, so its cells are kept too rather than dropped on a guess here.
        var unknownMethod = charges.Where(c => c.AllocationMethod is null).Select(c => c.LineNumber).ToHashSet();
        var known = charges.Select(c => c.LineNumber).ToHashSet();

        foreach (var allocation in allocations)
        {
            if (!known.Contains(allocation.ChargeLineNumber)) continue;
            if (!manualLines.Contains(allocation.ChargeLineNumber) && !unknownMethod.Contains(allocation.ChargeLineNumber)) continue;

            table.Rows.Add(allocation.ChargeLineNumber, allocation.PurchaseLineId, allocation.AmountBase);
        }

        return table;
    }
}
