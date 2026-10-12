namespace Inventory_Shipment.Model.DTOs.Logistics;

/* Container charges imported from an Excel file (Logistics › Containers, "Import charges from Excel…").
   ONE ROW = ONE CHARGE ON ONE CONTAINER: the whole amount on that container, divided over its items by the
   allocation method. Nothing new in the database: every row goes through usp_ContainerCharge_Create (or
   _CopyToContainers for the rows of one provider invoice, so they share a charge group) and _Post. */

/// <summary>
/// The verdict on one imported row. Strings rather than an enum, like the invoice import: the client renders
/// them as badges and sends them back with the rows.
/// </summary>
public static class ContainerChargeImportStatus
{
    public const string Valid = "Valid";

    /// <summary>Imported, but worth a look: a duplicate, a late charge, an item without weight...</summary>
    public const string Warning = "Warning";

    /// <summary>Never imported.</summary>
    public const string Error = "Error";
}

/// <summary>What happened to one row at the import.</summary>
public static class ContainerChargeImportOutcome
{
    /// <summary>Created and posted.</summary>
    public const string Posted = "Posted";

    /// <summary>Created as a draft: posting was not asked, or was refused (the message says why).</summary>
    public const string Draft = "Draft";

    /// <summary>Not created: the message is the reason.</summary>
    public const string Failed = "Failed";
}

/// <summary>
/// One row as the FILE says it, before anything is looked up. Every value is nullable and a value that would
/// not read (an amount of "abc") arrives as null with its text beside it, so the message can quote it: the
/// parser never refuses a row, only a file.
/// </summary>
public sealed class ContainerChargeImportRow
{
    /// <summary>The Excel row number: "row 5" is the row a person's cursor lands on.</summary>
    public int RowNumber { get; init; }

    /// <summary>The container number (MSKU1234565) or the app reference (KTG-2026-0031).</summary>
    public string? Container { get; init; }

    /// <summary>The code or the name of a charge type.</summary>
    public string? ChargeType { get; init; }

    public decimal? Amount { get; init; }

    /// <summary>What the cell said when <see cref="Amount"/> could not be read from it.</summary>
    public string? RawAmount { get; init; }

    /// <summary>A currency code; blank = the base currency.</summary>
    public string? Currency { get; init; }

    /// <summary>Blank = today.</summary>
    public DateOnly? ChargeDate { get; init; }

    public string? RawChargeDate { get; init; }

    /// <summary>Blank = the rate of the charge date.</summary>
    public decimal? ExchangeRate { get; init; }

    public string? RawExchangeRate { get; init; }

    /// <summary>A supplier's code or name; blank = no provider.</summary>
    public string? Provider { get; init; }

    /// <summary>The provider's invoice number: the charge's Reference.</summary>
    public string? ProviderInvoiceNo { get; init; }

    /// <summary>Value | Quantity | Weight | Volume; blank = the charge type's.</summary>
    public string? Allocation { get; init; }

    public string? Notes { get; init; }
}

/// <summary>
/// One row after it has been judged: the verdict, the message, what the file said and every value RESOLVED
/// against master data. The client shows it in the preview and sends it back as it came to import it: the
/// import works from the resolved ids and values, never from the text again.
/// </summary>
public sealed class ContainerChargeImportValidatedRow
{
    public int RowNumber { get; set; }

    /// <summary>Valid | Warning | Error — see <see cref="ContainerChargeImportStatus"/>.</summary>
    public string Status { get; set; } = ContainerChargeImportStatus.Valid;

    /// <summary>Every problem with the row, one sentence each; null on a row with nothing to say.</summary>
    public string? Message { get; set; }

    /* ── the container ── */

    /// <summary>What the file said.</summary>
    public string? ContainerInput { get; set; }

    public int? ContainerId { get; set; }
    public string? ContainerRef { get; set; }
    public string? ContainerNo { get; set; }

    /// <summary>1 Draft … 6 Offloaded, 7 Closed, 8 Cancelled.</summary>
    public byte? ContainerStatus { get; set; }

    public string? ContainerStatusName { get; set; }

    /* ── the charge type ── */

    public string? ChargeTypeInput { get; set; }
    public int? ChargeTypeId { get; set; }
    public string? ChargeCode { get; set; }
    public string? ChargeName { get; set; }
    public bool? IncludeInLandedCost { get; set; }

    /* ── the amount, its currency and rate ── */

    /// <summary>In the charge's currency, rounded to the cent.</summary>
    public decimal? Amount { get; set; }

    public string? RawAmount { get; set; }

    public string? CurrencyInput { get; set; }
    public int? CurrencyId { get; set; }
    public string? CurrencyCode { get; set; }
    public bool IsBaseCurrency { get; set; }

    public DateOnly? ChargeDate { get; set; }
    public string? RawChargeDate { get; set; }

    /// <summary>The Charge Date cell was blank: today.</summary>
    public bool ChargeDateDefaulted { get; set; }

    /// <summary>The rate the charge will carry: the one typed, else the rate of the charge date (1 for the base currency).</summary>
    public decimal? ExchangeRate { get; set; }

    public string? RawExchangeRate { get; set; }

    /// <summary>The Exchange Rate cell was blank: the rate was looked up for the charge date.</summary>
    public bool ExchangeRateLookedUp { get; set; }

    /// <summary>Amount ÷ rate, rounded to the cent — what the charge adds to the cost.</summary>
    public decimal? AmountBase { get; set; }

    /* ── the provider and the rest ── */

    public string? ProviderInput { get; set; }
    public int? ProviderPartyId { get; set; }
    public string? ProviderCode { get; set; }
    public string? ProviderName { get; set; }

    /// <summary>Provider Invoice No.: the charge's Reference.</summary>
    public string? Reference { get; set; }

    public string? AllocationInput { get; set; }

    /// <summary>The method the charge will use: Value, Quantity, Weight or Volume.</summary>
    public string? AllocationMethod { get; set; }

    /// <summary>The Allocation cell was blank: the charge type's method.</summary>
    public bool AllocationDefaulted { get; set; }

    public string? Notes { get; set; }

    /// <summary>
    /// The first row of the charge group this row will join (rows of one provider invoice: same charge type,
    /// provider, invoice no., date, currency, rate and notes); null when the row is a charge on its own.
    /// </summary>
    public int? GroupRowNumber { get; set; }
}

/// <summary>The answer to "what is in this file": every row with its verdict, and the counts.</summary>
public sealed class ContainerChargeImportValidation
{
    public string FileName { get; init; } = string.Empty;

    /// <summary>Data rows read from the file; blank rows are not counted.</summary>
    public int TotalRows { get; init; }

    public int ValidRows { get; init; }
    public int WarningRows { get; init; }
    public int ErrorRows { get; init; }

    /// <summary>Valid + Warning: what an import would create.</summary>
    public int ImportableRows => ValidRows + WarningRows;

    public string? BaseCurrencyCode { get; init; }

    public IReadOnlyList<ContainerChargeImportValidatedRow> Rows { get; init; } = [];
}

/// <summary>
/// The rows to create, as validation answered them (Error rows are skipped). post = true posts each charge
/// after creating it and needs containers.charges.post.
/// </summary>
public sealed class ContainerChargeImportRequest
{
    public bool Post { get; init; }

    /// <summary>The file's name, for the log.</summary>
    public string? FileName { get; init; }

    public IReadOnlyList<ContainerChargeImportValidatedRow> Rows { get; init; } = [];
}

/// <summary>What happened to one imported row.</summary>
public sealed class ContainerChargeImportRowResult
{
    public int RowNumber { get; init; }

    /// <summary>Posted | Draft | Failed — see <see cref="ContainerChargeImportOutcome"/>.</summary>
    public string Outcome { get; init; } = ContainerChargeImportOutcome.Failed;

    /// <summary>Failed: why. Draft when posting was asked: why it was not posted. Null otherwise.</summary>
    public string? Message { get; init; }

    /// <summary>The charge created; null when the row failed.</summary>
    public int? ChargeId { get; init; }

    public Guid? GroupId { get; init; }
    public int? ContainerId { get; init; }
    public string? ContainerRef { get; init; }
    public string? ContainerNo { get; init; }
    public string? ChargeCode { get; init; }
    public string? ChargeName { get; init; }
    public decimal? Amount { get; init; }
    public string? CurrencyCode { get; init; }
    public decimal? AmountBase { get; init; }
}

/// <summary>The import's result: one entry per row it tried, in the file's order, and the counts.</summary>
public sealed class ContainerChargeImportResult
{
    /// <summary>The rows the import tried (Valid and Warning).</summary>
    public int TotalRows { get; init; }

    /// <summary>Error rows sent with the request and left out.</summary>
    public int SkippedRows { get; init; }

    /// <summary>Charges created, posted or not.</summary>
    public int CreatedRows { get; init; }

    public int PostedRows { get; init; }

    /// <summary>Created and left as drafts.</summary>
    public int DraftRows { get; init; }

    public int FailedRows { get; init; }

    /// <summary>Whether posting was asked.</summary>
    public bool Post { get; init; }

    public IReadOnlyList<ContainerChargeImportRowResult> Rows { get; init; } = [];
}

/* ── read by the repository for the validation ─────────────────────────────────────────────── */

/// <summary>A container whose number or ref matches one of the file's (logistics.fn_ContainerNumberKey on both).</summary>
public sealed class ContainerChargeImportContainer
{
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public byte Status { get; init; }

    /// <summary>The container number as compared: upper case, without spaces, '-', '.', '/'.</summary>
    public string NumberKey { get; init; } = string.Empty;

    /// <summary>The ref as compared.</summary>
    public string RefKey { get; init; } = string.Empty;

    /// <summary>Lines with pieces (received once offloaded, loaded before).</summary>
    public int LineCount { get; init; }

    /// <summary>The first item on board without a weight (kg): a Weight charge cannot be posted.</summary>
    public string? ItemWithoutWeight { get; init; }

    /// <summary>The first item on board without a volume (CBM): a Volume charge cannot be posted.</summary>
    public string? ItemWithoutVolume { get; init; }
}

/// <summary>A draft or posted charge already on one of the matched containers: an import of the same file twice shows.</summary>
public sealed class ContainerChargeImportExistingCharge
{
    public int Id { get; init; }
    public int ContainerId { get; init; }
    public int ChargeTypeId { get; init; }
    public string? Reference { get; init; }
    public decimal Amount { get; init; }
    public int CurrencyId { get; init; }
    public DateTime ChargeDate { get; init; }
    public byte Status { get; init; }
}
