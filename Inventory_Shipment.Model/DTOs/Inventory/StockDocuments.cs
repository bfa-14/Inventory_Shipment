using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Inventory;

/// <summary>
/// The document lifecycle, as inventory.StockDocuments.Status stores it.
///
/// STRINGS ON THE WIRE, TINYINT IN THE DATABASE. The client renders a badge and filters by name; the
/// procedures compare against 1/2/3. Converting once here keeps the number out of the API contract,
/// where "status: 2" is a value nobody can read.
/// </summary>
public static class StockDocumentStatus
{
    public const byte DraftCode = 1;
    public const byte PostedCode = 2;
    public const byte CancelledCode = 3;

    public const string Draft = "Draft";
    public const string Posted = "Posted";
    public const string Cancelled = "Cancelled";

    public static string From(byte code) => code switch
    {
        PostedCode => Posted,
        CancelledCode => Cancelled,
        _ => Draft,
    };
}

/// <summary>The two inventory document kinds this controller serves. Purchase and Sales come later.</summary>
public static class StockDocumentTypes
{
    public const string In = "INV_IN";
    public const string Out = "INV_OUT";

    public static bool IsKnown(string? code)
        => string.Equals(code, In, StringComparison.OrdinalIgnoreCase)
        || string.Equals(code, Out, StringComparison.OrdinalIgnoreCase);
}

/// <summary>
/// One row of inventory.DocumentTypes — the CONFIGURATION of a document kind, not a document.
///
/// It is what tells a screen whether a draft already has a number (<see cref="NumberOnPost"/> false)
/// or shows "DRAFT" until it is posted, and whether the Reason field is required. Eight rows cover
/// every family; only the two Inventory ones are usable today.
/// </summary>
public sealed class DocumentTypeDto
{
    public int Id { get; init; }
    public string Code { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;

    /// <summary>Inventory | Purchase | Sales.</summary>
    public string Family { get; init; } = string.Empty;

    /// <summary>+1 adds stock, -1 removes it, 0 no ledger effect (orders).</summary>
    public short StockDirection { get; init; }

    public string NumberPrefix { get; init; } = string.Empty;
    public int NextNumber { get; init; }
    public byte NumberLength { get; init; }

    /// <summary>False: the number is assigned on the first save. True: drafts show DRAFT and the number is assigned on posting (gapless).</summary>
    public bool NumberOnPost { get; init; }

    public bool RequiresReason { get; init; }

    /// <summary>Cost | PriceList | None — what prices the lines: a typed cost, a price list, or nothing (orders).</summary>
    public string DefaultPricing { get; init; } = string.Empty;

    /// <summary>Whether the price / cost column may be typed. False on an Out: the average cost is applied.</summary>
    public bool PriceEditable { get; init; }

    /// <summary>True: one sequence per branch ("IN-KLW-000012"); false: one sequence for the company.</summary>
    public bool NumberPerBranch { get; init; }

    /// <summary>True: the year is part of the number and the sequence restarts every year ("SHR-2026-000001").</summary>
    public bool YearInNumber { get; init; }

    public bool IsActive { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

/// <summary>One reason an inventory document exists — opening balance, damage, transfer.</summary>
public sealed class StockReasonDto
{
    public int Id { get; init; }
    public string ReasonCode { get; init; } = string.Empty;
    public string ReasonName { get; init; } = string.Empty;

    /// <summary>In | Out | Both — which direction may use it.</summary>
    public string AppliesTo { get; init; } = string.Empty;

    public bool IsActive { get; init; }
}

/// <summary>One row of the documents list.</summary>
public sealed class StockDocumentListDto
{
    public int Id { get; init; }
    public string DocumentTypeCode { get; init; } = string.Empty;
    public string DocumentTypeName { get; init; } = string.Empty;
    public short StockDirection { get; init; }

    /// <summary>Null on a draft of a type that numbers on posting — the list shows a DRAFT badge for those.</summary>
    public string? DocumentNumber { get; init; }

    public DateTime DocumentDate { get; init; }
    public int BranchId { get; init; }
    public string BranchName { get; init; } = string.Empty;
    public int WarehouseId { get; init; }
    public string WarehouseName { get; init; } = string.Empty;
    public int? ReasonId { get; init; }
    public string? ReasonName { get; init; }
    public string? ReferenceNo { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;

    /// <summary>Draft | Posted | Cancelled.</summary>
    public string Status { get; init; } = StockDocumentStatus.Draft;

    public int TotalItems { get; init; }

    /// <summary>Base units, so a Box of 12 counts as 12 — the same measure the ledger uses.</summary>
    public decimal TotalQuantity { get; init; }

    public decimal TotalCost { get; init; }
    public DateTime? PostedAtUtc { get; init; }
    public string? PostedByName { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

/// <summary>One line of a document, with everything the grid draws and everything the ledger needs.</summary>
public sealed class StockDocumentLineDto
{
    public int Id { get; init; }

    /// <summary>
    /// The line's position, 1-based.
    ///
    /// CALLED LineNo ON THE WIRE AND LineNumber IN THE DATABASE, which is not an oversight: LINENO is
    /// a reserved T-SQL keyword, so the column could not carry the client's name without brackets
    /// everywhere it is touched. The repository maps the one to the other, in one place.
    /// </summary>
    public int LineNo { get; init; }

    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;

    public int ItemUnitId { get; init; }
    public string UnitTypeName { get; init; } = string.Empty;
    public string? SkuCode { get; init; }
    public string? Barcode { get; init; }

    /// <summary>How many base units this unit holds — a snapshot taken at save time, so a later change to the item cannot restate a posted document.</summary>
    public int PackingFormula { get; init; }

    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;

    public DateTime? ExpiryDate { get; init; }

    /// <summary>In the chosen unit.</summary>
    public int Quantity { get; init; }

    /// <summary>Quantity times the packing formula: what actually moves in the ledger.</summary>
    public decimal QuantityBase { get; init; }

    public decimal UnitCost { get; init; }
    public decimal LineTotal { get; init; }
    public string? Notes { get; init; }

    /// <summary>Stock in this item and warehouse right now, so the grid can warn before an Out is posted.</summary>
    public decimal OnHandBase { get; init; }
}

/// <summary>One attachment's metadata. The bytes are fetched separately, by id.</summary>
public sealed class StockDocumentFileDto
{
    public int Id { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public int SizeBytes { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
}

/// <summary>One entry of the document's own history: who did what, and when.</summary>
public sealed class StockDocumentAuditDto
{
    public string Action { get; init; } = string.Empty;
    public string? Details { get; init; }
    public string? UserName { get; init; }
    public DateTime AtUtc { get; init; }
}

/// <summary>One document, whole: the header, its lines, its attachments and its history.</summary>
public sealed class StockDocumentDto
{
    public int Id { get; init; }
    public int DocumentTypeId { get; init; }
    public string DocumentTypeCode { get; init; } = string.Empty;
    public string DocumentTypeName { get; init; } = string.Empty;
    public short StockDirection { get; init; }

    /// <summary>Whether this type numbers on posting. The screen says "Assigned on posting" rather than showing an empty box.</summary>
    public bool NumberOnPost { get; init; }

    public string? DocumentNumber { get; init; }
    public DateTime DocumentDate { get; init; }

    public int BranchId { get; init; }
    public string BranchCode { get; init; } = string.Empty;
    public string BranchName { get; init; } = string.Empty;

    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;

    public int? ReasonId { get; init; }
    public string? ReasonCode { get; init; }
    public string? ReasonName { get; init; }

    public string? ReferenceNo { get; init; }
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public byte DecimalPlaces { get; init; }
    public string? Notes { get; init; }

    public string Status { get; init; } = StockDocumentStatus.Draft;

    public int TotalItems { get; init; }
    public decimal TotalQuantity { get; init; }
    public decimal TotalCost { get; init; }

    public DateTime? PostedAtUtc { get; init; }
    public string? PostedByName { get; init; }
    public DateTime? CancelledAtUtc { get; init; }
    public string? CancelledByName { get; init; }
    public string? CancelReason { get; init; }

    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public string? UpdatedByName { get; init; }

    public byte[] RowVersion { get; init; } = [];

    /*
     * WHAT MAY BE DONE, COMPUTED HERE RATHER THAN BY THE CLIENT.
     *
     * The rule is the status, and the status is the server's. A client that worked these out itself
     * would be a second copy of the lifecycle — and the first time a fourth status appeared, every
     * screen would quietly offer the wrong buttons. These say only what the DOCUMENT allows; whether
     * this USER may do it is a permission, checked separately, and both have to be true.
     */
    public bool CanEdit => Status == StockDocumentStatus.Draft;
    public bool CanPost => Status == StockDocumentStatus.Draft;
    public bool CanCancel => Status == StockDocumentStatus.Posted;
    public bool CanDelete => Status == StockDocumentStatus.Draft;

    public IReadOnlyList<StockDocumentLineDto> Lines { get; init; } = [];
    public IReadOnlyList<StockDocumentFileDto> Files { get; init; } = [];
    public IReadOnlyList<StockDocumentAuditDto> Audit { get; init; } = [];
}

/* ── requests ──────────────────────────────────────────────────────────────────────────────── */

public sealed class SaveStockDocumentLineRequest
{
    public int LineNo { get; init; }

    [Range(1, int.MaxValue)]
    public int ItemId { get; init; }

    [Range(1, int.MaxValue)]
    public int ItemUnitId { get; init; }

    [Range(1, int.MaxValue)]
    public int WarehouseId { get; init; }

    public DateOnly? ExpiryDate { get; init; }

    [Range(1, int.MaxValue)]
    public int Quantity { get; init; }

    /// <summary>Per unit, base currency. Null is 0 on an In; ignored on an Out, which takes the average cost.</summary>
    [Range(0, double.MaxValue)]
    public decimal? UnitCost { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }
}

/// <summary>
/// Creating or replacing a draft.
///
/// THE LINES ARE A FULL REPLACE, not a patch. A grid where rows are added, reordered and deleted has
/// no stable identity to patch against, and the procedure rewrites them in one transaction — which is
/// also what makes the totals and the line numbering consistent afterwards.
/// </summary>
public sealed class SaveStockDocumentRequest
{
    [Required]
    [StringLength(20)]
    public string DocumentTypeCode { get; init; } = string.Empty;

    [Required]
    public DateOnly DocumentDate { get; init; }

    [Range(1, int.MaxValue)]
    public int BranchId { get; init; }

    /// <summary>
    /// Optional. The warehouse now lives on each LINE; the header keeps one only so that document
    /// lists, filters, reports and exports have one to show. Null = the first line's warehouse.
    /// </summary>
    public int? WarehouseId { get; init; }

    public int? ReasonId { get; init; }

    [StringLength(100)]
    public string? ReferenceNo { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    public IReadOnlyList<SaveStockDocumentLineRequest> Lines { get; init; } = [];

    /// <summary>Base64 of the row version last read. Null skips the check — used only when creating.</summary>
    public string? RowVersion { get; init; }
}

public sealed class PostStockDocumentRequest
{
    public string? RowVersion { get; init; }
}

public sealed class CancelStockDocumentRequest
{
    /// <summary>Required: a reversal that does not say why is a movement nobody can account for later.</summary>
    [Required]
    [StringLength(300, MinimumLength = 1)]
    public string Reason { get; init; } = string.Empty;

    public string? RowVersion { get; init; }
}

public sealed class StockDocumentQuery
{
    /// <summary>INV_IN or INV_OUT. Required by the controller: the two are different screens with different permissions.</summary>
    public string? DocumentTypeCode { get; init; }

    public string? Search { get; init; }
    public int? BranchId { get; init; }
    public int? WarehouseId { get; init; }

    /// <summary>Draft | Posted | Cancelled, or null for all.</summary>
    public string? Status { get; init; }

    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }

    public string SortBy { get; init; } = "DocumentDate";
    public string SortDir { get; init; } = "desc";

    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}

/// <summary>
/// The configuration page's save for one document type.
///
/// CODE, FAMILY AND STOCK DIRECTION ARE NOT HERE. They are what the procedures branch on; a type
/// whose direction could be flipped by a form would turn every posted document of it into a lie.
/// What a business owner changes is the wording, the numbering and the pricing rule.
/// </summary>
public sealed class UpdateDocumentTypeRequest
{
    [Required]
    [StringLength(100, MinimumLength = 1)]
    public string Name { get; init; } = string.Empty;

    [Required]
    [StringLength(10, MinimumLength = 1)]
    public string NumberPrefix { get; init; } = string.Empty;

    [Range(3, 10)]
    public byte NumberLength { get; init; } = 6;

    public bool NumberOnPost { get; init; }
    public bool RequiresReason { get; init; }

    /// <summary>Cost | PriceList | None.</summary>
    [Required]
    [RegularExpression("^(Cost|PriceList|None)$", ErrorMessage = "Default pricing must be Cost, PriceList or None.")]
    public string DefaultPricing { get; init; } = "Cost";

    public bool PriceEditable { get; init; } = true;
    public bool NumberPerBranch { get; init; } = true;

    /// <summary>The year as a segment of the number, with a sequence per year. Null leaves the stored value alone.</summary>
    public bool? YearInNumber { get; init; }

    public bool IsActive { get; init; } = true;

    /// <summary>Base64 ROWVERSION read with the type. Null skips the concurrency check.</summary>
    public string? RowVersion { get; init; }
}

/// <summary>
/// An imported file becoming stock documents: the header every document shares, and the lines the
/// server sorts into one document per warehouse.
/// </summary>
public sealed class ImportCreateStockDocumentsRequest
{
    [Required]
    public string DocumentTypeCode { get; init; } = string.Empty;

    [Required]
    public DateOnly DocumentDate { get; init; }

    [Range(1, int.MaxValue)]
    public int BranchId { get; init; }

    public int? ReasonId { get; init; }

    [StringLength(100)]
    public string? ReferenceNo { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    public IReadOnlyList<Model.DTOs.Documents.ImportCreateLine> Lines { get; init; } = [];

    /// <summary>True posts each created document at once; a refused posting leaves that one as a draft.</summary>
    public bool PostImmediately { get; init; }
}
