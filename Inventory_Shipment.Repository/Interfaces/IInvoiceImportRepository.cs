using Inventory_Shipment.Model.DTOs.Sales;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// The sales invoice import engine: validate a whole file's rows in one round trip, and record what
/// was imported.
/// </summary>
public interface IInvoiceImportRepository
{
    /// <summary>
    /// Judges every row against master data in ONE call — items, units, warehouses of the branch and
    /// the price list — and returns each one resolved, with a status and a message.
    ///
    /// A ROUND TRIP PER ROW WOULD BE THE OBVIOUS SHAPE AND IS THE WRONG ONE: two thousand rows is
    /// two thousand round trips, and the rules (a price that falls back from branch to all-branches,
    /// a unit chosen by barcode) are joins, which is what the database is for.
    /// </summary>
    /// <param name="checkStock">
    /// True makes a row that would take more than the stock on hand an Error, cumulatively with the
    /// rows above it for the same item and warehouse. Off for a stock-in import, where the shelf is
    /// about to be filled rather than emptied.
    /// </param>
    /// <exception cref="Exceptions.BusinessRuleException">
    /// 61008 when the branch, default warehouse or price list is missing or inactive, or the
    /// warehouse does not belong to the branch. These are header problems, not row problems: nothing
    /// in the file can be judged until they are fixed.
    /// </exception>
    Task<IReadOnlyList<InvoiceImportValidatedRow>> ValidateAsync(
        int branchId,
        int defaultWarehouseId,
        int? priceListId,
        bool allowPriceOverride,
        decimal maxDiscountPercent,
        bool checkStock,
        string? documentTypeCode,
        IReadOnlyList<InvoiceImportRow> rows,
        CancellationToken cancellationToken = default);

    /// <summary>Writes one audit row and returns its id.</summary>
    Task<int> LogAsync(InvoiceImportLogRequest request, int userId, CancellationToken cancellationToken = default);
}
