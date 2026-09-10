namespace Inventory_Shipment.Model.DTOs.Sales;

/// <summary>
/// The status of one imported row, as the validation procedure and the consolidation pass set it.
///
/// STRINGS RATHER THAN AN ENUM because the values are the procedure's own: it returns 'Valid',
/// 'Warning' and 'Error' as text, and the client renders them as badges. An enum here would mean a
/// mapping in both directions and a third representation to keep in step for no gain.
/// </summary>
public static class InvoiceImportStatus
{
    public const string Valid = "Valid";
    public const string Warning = "Warning";
    public const string Error = "Error";

    /// <summary>
    /// Absorbed into an earlier row by consolidation (spec rule 16). NOT a procedure status: the
    /// merge happens after validation, in the service, because it is about the file as a whole
    /// rather than about any one row. A merged row is neither imported nor rejected, so it is
    /// counted in neither total.
    /// </summary>
    public const string Merged = "Merged";
}

/// <summary>
/// One row as it was READ OUT OF THE EXCEL FILE, before the database has looked at it.
///
/// EVERYTHING IS NULLABLE AND THE ORIGINALS TRAVEL BESIDE THE PARSED VALUES. A cell holding "abc"
/// where a quantity belongs is not an error the parser may decide: the procedure writes the message,
/// in the same sentence it uses for every other bad quantity, and it can only do that if it is given
/// the text. So a value that would not parse arrives as NULL with its <see cref="RawQuantity"/> or
/// <see cref="RawExpiryDate"/> alongside, and the parser never rejects a single row.
/// </summary>
public sealed class InvoiceImportRow
{
    /// <summary>The Excel row number, so every message names the row a person can actually go and look at.</summary>
    public int RowNumber { get; init; }

    /// <summary>Item Code or a unit barcode. A barcode also settles which unit the row means.</summary>
    public string? ItemRef { get; init; }

    /// <summary>Unit type name or SKU. Blank means the item's sales unit.</summary>
    public string? UnitName { get; init; }

    /// <summary>Warehouse code or name. Blank means the invoice header's default warehouse.</summary>
    public string? WarehouseRef { get; init; }

    public decimal? Quantity { get; init; }

    /// <summary>What the cell said when <see cref="Quantity"/> could not be read from it.</summary>
    public string? RawQuantity { get; init; }

    /// <summary>A manual price. Honoured only for a caller holding sales.invoices.priceoverride.</summary>
    public decimal? UnitPrice { get; init; }

    public decimal? DiscountPercent { get; init; }

    public DateTime? ExpiryDate { get; init; }

    /// <summary>What the cell said when <see cref="ExpiryDate"/> could not be read from it.</summary>
    public string? RawExpiryDate { get; init; }

    public string? Notes { get; init; }
}

/// <summary>
/// One row after the database has judged it: the verdict, the message, and every value RESOLVED
/// against master data (the item, its unit, the warehouse, the effective price).
///
/// THE RESOLVED VALUES ARE WHAT THE INVOICE LINE IS BUILT FROM. The client shows ItemCode and
/// ItemName so a person can see the file was understood, and hands ItemId / ItemUnitId /
/// WarehouseId back when the lines are added — the text in the spreadsheet is never used again.
/// </summary>
public sealed class InvoiceImportValidatedRow
{
    public int RowNumber { get; set; }

    /// <summary>Valid | Warning | Error | Merged — see <see cref="InvoiceImportStatus"/>.</summary>
    public string Status { get; set; } = InvoiceImportStatus.Valid;

    /// <summary>Every problem found with the row, in one sentence. Null on a row with nothing to say.</summary>
    public string? Message { get; set; }

    /// <summary>What the file said, kept so an error about an unknown code can quote it.</summary>
    public string? ItemRef { get; set; }

    public int? ItemId { get; set; }
    public string? ItemCode { get; set; }
    public string? ItemName { get; set; }

    public int? ItemUnitId { get; set; }
    public string? UnitTypeName { get; set; }

    /// <summary>How many base units this unit holds. Shown so "Box" is not ambiguous on screen.</summary>
    public decimal? PackingFormula { get; set; }

    public int? WarehouseId { get; set; }
    public string? WarehouseCode { get; set; }
    public string? WarehouseName { get; set; }

    /// <summary>Whole pieces. Null on a row whose quantity was unusable.</summary>
    public int? Quantity { get; set; }

    /// <summary>What will actually be charged: the manual price where it was accepted, else the system price.</summary>
    public decimal? UnitPrice { get; set; }

    /// <summary>Manual | Branch | AllBranches — where <see cref="UnitPrice"/> came from. Null when there was none.</summary>
    public string? PriceSource { get; set; }

    /// <summary>The price the file asked for, whether or not it was honoured.</summary>
    public decimal? ManualPrice { get; set; }

    public decimal DiscountPercent { get; set; }

    public DateTime? ExpiryDate { get; set; }

    public string? Notes { get; set; }
}

/// <summary>
/// The answer to "what is in this file, and what would happen if I imported it" — the whole of what
/// the wizard's second step draws.
///
/// THE COUNTS ARE NOT DERIVED BY THE CLIENT, deliberately: merged rows are in <see cref="Rows"/> so
/// the preview can show what happened to them, and a client counting statuses itself would have to
/// know that Merged belongs to neither total. The server counts once and everybody agrees.
/// </summary>
public sealed class ImportValidationResult
{
    public string FileName { get; init; } = string.Empty;

    /// <summary>Data rows read from the file. Blank rows are not read and are not counted.</summary>
    public int TotalRows { get; init; }

    public int ValidRows { get; init; }
    public int WarningRows { get; init; }
    public int ErrorRows { get; init; }

    public IReadOnlyList<InvoiceImportValidatedRow> Rows { get; init; } = [];
}

/// <summary>What the client asks to be written to the import audit log once the lines are taken.</summary>
public sealed class InvoiceImportLogRequest
{
    public int BranchId { get; init; }
    public int WarehouseId { get; init; }
    public int PriceListId { get; init; }
    public string FileName { get; init; } = string.Empty;
    public int TotalRows { get; init; }
    public int ImportedRows { get; init; }
    public int WarningRows { get; init; }
    public int RejectedRows { get; init; }

    /// <summary>
    /// The client's draft id, until the invoice exists.
    ///
    /// IT IS THE WHOLE REASON THIS LOG CAN BE WRITTEN BEFORE THE INVOICE IS SAVED. The import happens
    /// on a draft that has no id yet; usp_InvoiceImport_AttachInvoice later stamps every log row
    /// carrying this reference with the invoice's id, so the audit trail survives a save that may
    /// come minutes later, or never.
    /// </summary>
    public string? DraftReference { get; init; }
}
