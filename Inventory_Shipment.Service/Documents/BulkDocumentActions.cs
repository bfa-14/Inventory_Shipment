using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;

namespace Inventory_Shipment.Service.Documents;

/// <summary>
/// The loop behind every bulk post and bulk delete, whatever the document family.
///
/// ONE CALL PER DOCUMENT, EACH IN ITS OWN TRANSACTION. The families' post and delete procedures are
/// transactional per document; running them one after another means a refusal in the third leaves
/// the first two posted and the fourth still tried. A single transaction around the batch would be
/// the opposite of what a list page wants: nobody selects twenty drafts hoping that one bad one
/// undoes the nineteen.
///
/// THE FAMILIES PASS A DELEGATE, NOT A TYPE. Posting a stock document, a sales invoice and a purchase
/// order are three services with three permission sets; what they share is "do this to an id and
/// tell me the number or the refusal", which is the delegate's whole signature.
/// </summary>
public static class BulkDocumentActions
{
    /// <summary>
    /// Runs <paramref name="action"/> once per id, in the order given, and assembles the result.
    /// A duplicated id is acted on once; the result keeps the first occurrence's position.
    /// </summary>
    /// <param name="action">Acts on one document; its value is the document number afterwards (null for a draft).</param>
    public static async Task<BulkActionResult> RunAsync(
        IReadOnlyList<int> ids, Func<int, Task<Result<string?>>> action)
    {
        var results = new List<BulkActionItemResult>(ids.Count);
        var seen = new HashSet<int>();

        foreach (var id in ids)
        {
            if (!seen.Add(id))
            {
                continue;
            }

            Result<string?> outcome;
            try
            {
                outcome = await action(id);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // The others must still run: an exception in one is that one's failure, not the batch's.
                outcome = Result<string?>.Failure(ErrorType.Validation, ex.Message, "ERROR");
            }

            results.Add(BulkActionResult.Item(id, outcome));
        }

        return BulkActionResult.From(results);
    }
}
