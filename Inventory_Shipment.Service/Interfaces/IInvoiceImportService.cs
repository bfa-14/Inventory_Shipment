using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Sales;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Importing invoice lines from an Excel file: read the file, judge every row against master data,
/// and record what was taken.
///
/// IT IMPORTS NOTHING ITSELF, and that is deliberate. The rows come back to the caller and the
/// INVOICE PAGE adds them to its draft; nothing is written to an invoice here, because the user has
/// not agreed to the lines yet and half of them may be about to be corrected. The only thing this
/// writes is the audit row, once the caller says the lines were taken.
/// </summary>
public interface IInvoiceImportService
{
    /// <summary>The blank template, generated from the same headings the parser matches.</summary>
    byte[] GenerateTemplate();

    /// <summary>The non-valid rows of a validated file, as a workbook to correct and re-upload.</summary>
    byte[] GenerateErrorReport(IReadOnlyList<InvoiceImportValidatedRow> rows);

    /// <summary>
    /// Reads the file and judges every row: what it means, what it would cost, and what is wrong
    /// with it.
    /// </summary>
    /// <param name="file">The uploaded .xlsx.</param>
    /// <param name="fileName">The name to show and to record in the audit log.</param>
    /// <param name="priceListId">
    /// The price list to price against, or NULL for STOCK MODE — an Inventory In / Out import, which
    /// has no selling price at all and reads the Unit Price column as the unit cost.
    /// </param>
    /// <param name="userPermissions">
    /// The caller's permission codes. sales.invoices.priceoverride among them is what decides whether
    /// a price typed into the file is honoured — read from the token rather than passed as a flag, so
    /// a client cannot ask for the override it was not granted.
    /// </param>
    Task<Result<ImportValidationResult>> ValidateAsync(
        Stream file,
        string fileName,
        long fileLength,
        int branchId,
        int warehouseId,
        int? priceListId,
        IReadOnlySet<string> userPermissions,
        CancellationToken cancellationToken = default);

    /// <summary>Records one import in the audit log and returns the row's id.</summary>
    Task<Result<int>> LogAsync(InvoiceImportLogRequest request, int userId, CancellationToken cancellationToken = default);
}
