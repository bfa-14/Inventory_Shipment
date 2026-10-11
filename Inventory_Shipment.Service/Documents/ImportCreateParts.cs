using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Documents;

/// <summary>
/// How an import-create cuts a file's lines into documents, for the families that let the user
/// choose: sales invoices and stock documents (Inventory In / Out).
///
/// THE CHOICE IS THE USER'S, MADE AT EACH IMPORT. By default a file naming several warehouses becomes
/// ONE document whose lines each keep their own warehouse — what the import has done since the
/// warehouse moved to the line. Asked to split, it becomes one document per warehouse instead, the
/// way a branch that books each warehouse separately wants it. Both families cut the lines the same
/// way, so the rule lives here once.
///
/// ONE PART IS ONE DOCUMENT, CREATED (AND POSTED) ON ITS OWN. Each family saves every part through
/// its ordinary save and post, so a refusal in one part is that part's failure and the others still
/// go in — the same reasoning as <see cref="BulkDocumentActions"/>. Split, an unexpected error is
/// that part's failure too (<see cref="UnexpectedFailureAsync"/>): by then the earlier parts'
/// documents are committed, and the result is the only list of them the page will get.
/// </summary>
public static class ImportCreateParts
{
    /// <summary>
    /// The lines as the documents to create: all of them in one, or one group per warehouse — the
    /// groups in the order of each warehouse's first line, the lines in the file's order within each.
    /// </summary>
    public static IReadOnlyList<IReadOnlyList<ImportCreateLine>> Of(IReadOnlyList<ImportCreateLine> lines, bool splitByWarehouse)
        => splitByWarehouse
            // GroupBy keeps the order in which each key first appears, and each group the source order.
            ? lines.GroupBy(line => line.WarehouseId).Select(group => (IReadOnlyList<ImportCreateLine>)group.ToList()).ToList()
            : [lines];

    /// <summary>
    /// The name of the warehouse whose document could not be created, so its failure can say which.
    ///
    /// BEST EFFORT, AND IT MUST NOT THROW: it only labels a failure that is already being reported,
    /// and an exception here would replace the whole result — the documents already created with it.
    /// Null when the warehouse cannot be read; the failure still carries its id.
    /// </summary>
    public static async Task<string?> WarehouseNameAsync(
        IWarehouseRepository warehouses, int warehouseId, ILogger logger, CancellationToken cancellationToken)
    {
        try
        {
            return (await warehouses.GetByIdAsync(warehouseId, cancellationToken))?.WarehouseName;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Warehouse {WarehouseId} could not be read to name an import-create failure", warehouseId);
            return null;
        }
    }

    /// <summary>
    /// The failure of one warehouse's document that ended in an unexpected error (a database failure,
    /// a timeout, a dropped connection) rather than a refusal; the cause is logged here.
    ///
    /// SPLIT, AN EXCEPTION IS ONE DOCUMENT'S, NOT THE FILE'S. The documents of the warehouses before it
    /// are already committed, perhaps posted (stock moved, a Cash invoice's receipt taken). Escaping,
    /// the exception would turn the call into a 500 that loses them from the result, and the page's
    /// retry would create them a second time. Caught, it is listed like a refusal and the next
    /// warehouse still goes in.
    ///
    /// THE MESSAGE SAYS ONLY WHAT IS KNOWN. <paramref name="createdId"/> is set when the draft was saved
    /// and the error came while posting it: the caller lists that draft too, but whether the posting
    /// went through before the error is unknown, so the reader is sent to look before posting again.
    /// The exception's own text stays in the log; a database message is not for the page.
    /// </summary>
    /// <param name="noun">What the family calls the document: "invoice", "document".</param>
    public static async Task<ImportCreateFailure> UnexpectedFailureAsync(
        Exception exception, string noun, IWarehouseRepository warehouses, int warehouseId, int? createdId,
        ILogger logger, CancellationToken cancellationToken)
    {
        logger.LogError(exception,
            "Import-create of the {Noun} for warehouse {WarehouseId} failed unexpectedly (saved as {DocumentId})",
            noun, warehouseId, createdId);

        return new ImportCreateFailure
        {
            WarehouseId = warehouseId,
            WarehouseName = await WarehouseNameAsync(warehouses, warehouseId, logger, cancellationToken),
            Code = "ERROR",
            Message = createdId is null
                ? $"The {noun} for this warehouse could not be created (unexpected error). Check the {noun} list before importing this file again."
                : $"The {noun} was created, but posting it ended in an unexpected error. Open it to see whether it was posted before posting it again.",
        };
    }
}
