using System.ComponentModel.DataAnnotations;
using Inventory_Shipment.Model.Enums;

namespace Inventory_Shipment.Model.DTOs.Inventory.Transfers;

/// <summary>
/// (93) BATCH, SERIAL AND EXPIRY ON TRANSFERS ("tracking", never "details": that word is the header's "Save details").
/// A dispatch line of a tracked item carries its rows - one serial no. per piece, batch rows (batch no., expiry, pcs) or
/// expiry rows (expiry, pcs) - and its receipt says, row by row, what arrived and what was lost. Every rule (format,
/// length, duplicates, sums, "already on the way") is the database's: inventory.fn_TransferDispatch_TrackingProblems for
/// the dispatch, the receive core's checks for the receipt. The API only shapes the rows into the two table types,
/// refuses a runaway request of more than <see cref="MaxRows"/> rows before the database, and reads the rows back per
/// posting (never in the order's Get, B18: 10,000 serials would make every answer heavy).
/// </summary>
public static class TransferTrackingRules
{
    /// <summary>B14: at most this many tracking rows in one dispatch and in one receipt (the movement import's ceiling).</summary>
    public const int MaxRows = 10_000;

    public const string TooManyDispatchRows = "A dispatch holds at most 10,000 batch, serial or expiry rows.";

    public const string TooManyReceiptRows = "A receipt holds at most 10,000 batch, serial or expiry rows: receive one dispatch at a time.";

    /// <summary>A tracking row of a dispatch named twice: the receipt type's key is the dispatch row.</summary>
    public const string DuplicateReceiptRow = "Each batch, serial or expiry row of a dispatch may appear only once in a receipt.";
}

/// <summary>
/// One row a dispatch line carries (inventory.tvp_TransferDispatchTracking). The numbers go as typed: the database trims
/// them (CR, LF, tab, no-break space, BOM and spaces at both ends), puts them in capitals and checks them, one rule for
/// the dialog's Check and the posting. 100 characters reach it, so "longer than 50 characters" is its sentence.
/// </summary>
public sealed class TransferDispatchTrackingRequest
{
    /// <summary>Batch items: the batch no.</summary>
    [StringLength(100)]
    public string? BatchNo { get; init; }

    /// <summary>Serial items: the serial no. (a TVS chassis no. has 17 characters).</summary>
    [StringLength(100)]
    public string? SerialNo { get; init; }

    /// <summary>Required when the item requires an expiry date, and on every row of an expiry-only item.</summary>
    public DateOnly? ExpiryDate { get; init; }

    /// <summary>Pieces of the row: 1 for a serial (the default when not sent), the batch's or the date's pcs otherwise.</summary>
    public int QuantityBase { get; init; } = 1;
}

/// <summary>
/// One dispatch row a receipt line settles (inventory.tvp_TransferReceiptTracking): arrived and written off as lost. A
/// row left out is Still coming. A serial is one piece: received 1 or lost 1.
/// </summary>
public sealed class TransferReceiptTrackingRequest
{
    /// <summary>The dispatch's tracking row (<see cref="TransferTrackingRowDto.Id"/>, read with onTheWayOnly=true).</summary>
    public int DispatchTrackingId { get; init; }

    public int ReceivedBase { get; init; }

    public int LostBase { get; init; }
}

/// <summary>One problem of a dispatch's rows (fn_TransferDispatch_TrackingProblems): an Error refuses the posting, a Warning only says.</summary>
public sealed class TransferTrackingProblemDto
{
    /// <summary>The rule's place in the order of the checks (5 the ceiling … 24 the sums, 90 already on the way, 100-103 warnings).</summary>
    public int Seq { get; init; }

    /// <summary>Error | Warning.</summary>
    public string Severity { get; init; } = TransferTrackingSeverities.Error;

    /// <summary>The order line the problem is about (null for the dispatch as a whole).</summary>
    public int? TransferOrderLineId { get; init; }

    public int? LineNumber { get; init; }

    /// <summary>The row's place in the line's list, 1-based, as the dialog sent it; null when the problem is the line's.</summary>
    public int? RowNumber { get; init; }

    /// <summary>The database's sentence, shown as it comes.</summary>
    public string Message { get; init; } = string.Empty;
}

public static class TransferTrackingSeverities
{
    public const string Error = "Error";
    public const string Warning = "Warning";
}

/// <summary>
/// POST {id}/dispatch/check-tracking: every problem of the dispatch as typed (its errors; its warnings, or those of
/// forLineId only). Empty = all good. Nothing is written and no lock is taken; the posting checks the errors again.
/// </summary>
public sealed class CheckDispatchTrackingResult
{
    public IReadOnlyList<TransferTrackingProblemDto> Problems { get; init; } = [];
    public int ErrorCount { get; init; }
    public int WarningCount { get; init; }
}

/// <summary>
/// One tracking row of a dispatch or receipt (inventory.usp_TransferPosting_Tracking), with what became of it. Rows are
/// never changed by a reversal: a reversed posting's rows read "Reversed".
/// </summary>
public sealed class TransferTrackingRowDto
{
    public int Id { get; init; }
    public int PostingLineId { get; init; }
    public int PostingLineNumber { get; init; }
    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;

    /// <summary>1..n within the posting line: the order typed (dispatch), the dispatch rows' order (receipt).</summary>
    public int RowNumber { get; init; }

    /// <summary>Serial | Batch | Expiry: the line's kind.</summary>
    public TrackingKind Kind { get; init; }

    /// <summary>In capitals, as stored.</summary>
    public string? SerialNo { get; init; }

    public string? BatchNo { get; init; }
    public DateOnly? ExpiryDate { get; init; }

    /// <summary>Dispatch: pcs sent; receipt: pcs received.</summary>
    public int QuantityBase { get; init; }

    /// <summary>Receipt rows: pcs written off as lost.</summary>
    public int LostBase { get; init; }

    /// <summary>Dispatch rows: received + written off by posted receipts.</summary>
    public int SettledBase { get; init; }

    /// <summary>Dispatch rows of a posted dispatch: quantity − settled; 0 otherwise.</summary>
    public int OnTheWayBase { get; init; }

    /// <summary>Receipt rows: the dispatch row received, and its dispatch's number.</summary>
    public int? DispatchTrackingId { get; init; }

    public string? DispatchNumber { get; init; }

    /// <summary>Reversed | OnTheWay | PartlyReceived | Received | Lost | Settled | PartlyLost.</summary>
    public string State { get; init; } = string.Empty;

    /// <summary>"Received by TRR-BR-002-000007", "Written off by TRR-… (Missing / stolen)", "2 received, 1 written off, 3 on the way".</summary>
    public string StateText { get; init; } = string.Empty;
}

/// <summary>A serial no. received into the order's From by a transfer and not sent since (B12): offered by "Known at {From}…".</summary>
public sealed class TransferSerialSuggestionDto
{
    public string SerialNo { get; init; } = string.Empty;
    public DateOnly? ExpiryDate { get; init; }
    public string? ReceivedByNumber { get; init; }
    public DateOnly? ReceivedOn { get; init; }
}

/// <summary>GET {id}/lines/{lineId}/tracking-suggestions: the line's tracking kind now, and the serials known at From (serial items only).</summary>
public sealed class TransferTrackingSuggestionsDto
{
    /// <summary>Serial | Batch | Expiry | null: what Dispatch… asks for this line now.</summary>
    public TrackingKind? TrackingKind { get; init; }

    /// <summary>At most 2,000, by date received then serial no.; empty for any kind but Serial.</summary>
    public IReadOnlyList<TransferSerialSuggestionDto> Serials { get; init; } = [];
}
