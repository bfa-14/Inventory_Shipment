using System.ComponentModel.DataAnnotations;
using Inventory_Shipment.Model.DTOs.Inventory;

namespace Inventory_Shipment.Model.DTOs.Sales;

/// <summary>
/// The Sales document family's type codes. Only the invoice is exposed today; the order and the
/// return share the same tables and procedures and arrive later.
/// </summary>
public static class SalesDocumentTypes
{
    public const string Invoice = "SINV";
    public const string Return = "SRET";
}

/// <summary>
/// Where a line's price came from, as sales.SalesDocumentLines.PriceSource stores it.
///
/// THE DIFFERENCE IS AN AUDIT FACT, not decoration. A line priced from the list is the system's
/// number; a Manual one is somebody's decision, made under a permission, and the invoice has to be
/// able to say which of its lines are which when the question is asked later.
/// </summary>
public static class PriceSources
{
    public const string PriceList = "PriceList";
    public const string Manual = "Manual";
}

/// <summary>How the exchange rate was chosen: 1 Official (the default), 2 Non-official, 3 Market.</summary>
public static class RateTypes
{
    public const byte Official = 1;
    public const byte NonOfficial = 2;
    public const byte Market = 3;

    public static bool IsKnown(byte value) => value is Official or NonOfficial or Market;
}

/// <summary>One row of the invoices list.</summary>
public sealed class SalesInvoiceListDto
{
    public int Id { get; init; }
    public string DocumentTypeCode { get; init; } = string.Empty;
    public string DocumentTypeName { get; init; } = string.Empty;

    /// <summary>Null while a draft: invoices are numbered on posting, so the series has no gaps.</summary>
    public string? DocumentNumber { get; init; }

    public DateTime DocumentDate { get; init; }
    public DateTime? DueDate { get; init; }
    public int BranchId { get; init; }
    public string BranchName { get; init; } = string.Empty;
    public int WarehouseId { get; init; }
    public string WarehouseName { get; init; } = string.Empty;
    public int ClientId { get; init; }
    public string ClientCode { get; init; } = string.Empty;
    public string ClientName { get; init; } = string.Empty;
    public int? SalesmanId { get; init; }
    public string? SalesmanName { get; init; }
    public int PriceListId { get; init; }
    public string PriceListName { get; init; } = string.Empty;

    /// <summary>The invoice currency — the price list's, snapshotted on the header.</summary>
    public string CurrencyCode { get; init; } = string.Empty;
    public string? CurrencySymbol { get; init; }
    public byte DecimalPlaces { get; init; }
    public decimal ExchangeRate { get; init; }

    public string? ReferenceNo { get; init; }

    /// <summary>Draft | Posted | Cancelled.</summary>
    public string Status { get; init; } = StockDocumentStatus.Draft;

    public int TotalItems { get; init; }
    public decimal TotalQuantity { get; init; }
    public decimal Subtotal { get; init; }
    public decimal TotalDiscount { get; init; }

    /// <summary>In the invoice currency.</summary>
    public decimal TotalAmount { get; init; }

    /// <summary>The same figure in the base currency, for reporting across lists in different currencies.</summary>
    public decimal TotalAmountBase { get; init; }

    public DateTime? PostedAtUtc { get; init; }
    public string? PostedByName { get; init; }
    public DateTime? CancelledAtUtc { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

/// <summary>One invoice line, with what the grid draws and what the ledger took.</summary>
public sealed class SalesInvoiceLineDto
{
    public int Id { get; init; }

    /// <summary>1-based. LineNo on the wire, LineNumber in the database — LINENO is a reserved T-SQL keyword.</summary>
    public int LineNo { get; init; }

    public int ItemId { get; init; }
    public string ItemCode { get; init; } = string.Empty;
    public string ItemName { get; init; } = string.Empty;
    public int ItemUnitId { get; init; }
    public string UnitTypeName { get; init; } = string.Empty;
    public string? SkuCode { get; init; }
    public string? Barcode { get; init; }

    /// <summary>Base units per unit — a snapshot, so a later change to the item cannot restate a posted invoice.</summary>
    public int PackingFormula { get; init; }

    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;
    public DateTime? ExpiryDate { get; init; }

    /// <summary>In the chosen unit.</summary>
    public int Quantity { get; init; }

    /// <summary>Quantity times the packing formula: what leaves the ledger.</summary>
    public decimal QuantityBase { get; init; }

    /// <summary>Per unit, in the invoice currency. What was actually charged.</summary>
    public decimal UnitPrice { get; init; }

    public decimal DiscountPercent { get; init; }
    public decimal LineDiscount { get; init; }
    public decimal LineTotal { get; init; }

    /// <summary>PriceList or Manual — see <see cref="PriceSources"/>.</summary>
    public string PriceSource { get; init; } = PriceSources.PriceList;

    /// <summary>The cost of goods per base unit at posting time, in the base currency. Null until posted.</summary>
    public decimal? UnitCostBase { get; init; }

    /* THE COST SNAPSHOT, frozen when the invoice was posted. Null on a draft, and null for a reader
       without sales.profit.view — a price is everybody's business, a margin is not. */

    /// <summary>What the goods had cost the company FOB when this line was sold.</summary>
    public decimal? FobCostAtSale { get; init; }

    /// <summary>The item's landed cost at that moment — what replacing the goods would have cost.</summary>
    public decimal? LastCostAtSale { get; init; }

    /// <summary>The line's sale after discount, in the base currency.</summary>
    public decimal? NetSalesBase { get; init; }

    /// <summary>Cost of goods sold: base quantity × the average cost at posting.</summary>
    public decimal? CogsBase { get; init; }

    public decimal? GrossProfitBase { get; init; }

    /// <summary>Gross profit as a percentage OF NET SALES. Null when the line sold for nothing.</summary>
    public decimal? GrossProfitPct { get; init; }

    /// <summary>How much of this line has come back on a sales return, in base units.</summary>
    public decimal ReturnedQuantityBase { get; init; }

    /// <summary>What can still be returned: base quantity less what already came back.</summary>
    public decimal RemainingBase { get; init; }

    /// <summary>The Excel row this line came from, where it came from a file. What the row-number tooltip shows.</summary>
    public int? ImportRowNumber { get; init; }

    public string? Notes { get; init; }

    /// <summary>Stock in this item and warehouse right now, so the grid can warn before posting.</summary>
    public decimal OnHandBase { get; init; }

    /// <summary>The item's average cost as it stands NOW — what a line posted today would be costed at.</summary>
    public decimal? ItemAverageCost { get; init; }

    /// <summary>The price list price as it stands NOW — informational, so a Manual line can show what it overrode.</summary>
    public decimal? SystemPrice { get; init; }
}

public sealed class SalesInvoiceFileDto
{
    public int Id { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public int SizeBytes { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public string? CreatedByName { get; init; }
}

public sealed class SalesInvoiceAuditDto
{
    public string Action { get; init; } = string.Empty;
    public string? Details { get; init; }
    public string? UserName { get; init; }
    public DateTime AtUtc { get; init; }
}

/// <summary>One invoice, whole: header, lines, attachments and history.</summary>
public sealed class SalesInvoiceDto
{
    public int Id { get; init; }
    public int DocumentTypeId { get; init; }
    public string DocumentTypeCode { get; init; } = string.Empty;
    public string DocumentTypeName { get; init; } = string.Empty;
    public bool NumberOnPost { get; init; }
    public string? DocumentNumber { get; init; }
    public DateTime DocumentDate { get; init; }
    public DateTime? DueDate { get; init; }

    public int BranchId { get; init; }
    public string BranchCode { get; init; } = string.Empty;
    public string BranchName { get; init; } = string.Empty;
    public int WarehouseId { get; init; }
    public string WarehouseCode { get; init; } = string.Empty;
    public string WarehouseName { get; init; } = string.Empty;

    public int ClientId { get; init; }
    public string ClientCode { get; init; } = string.Empty;
    public string ClientName { get; init; } = string.Empty;
    public string? ClientPhone { get; init; }
    public string? ClientEmail { get; init; }
    public string? ClientAddress { get; init; }

    public int? SalesmanId { get; init; }
    public string? SalesmanCode { get; init; }
    public string? SalesmanName { get; init; }

    public int PriceListId { get; init; }
    public string PriceListCode { get; init; } = string.Empty;
    public string PriceListName { get; init; } = string.Empty;

    /* THE INVOICE CURRENCY IS THE PRICE LIST'S, and it is snapshotted here rather than joined live: a
       price list whose currency is changed later must not restate an invoice already issued. */
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public string CurrencyName { get; init; } = string.Empty;
    public string? CurrencySymbol { get; init; }
    public byte DecimalPlaces { get; init; }
    public bool IsBaseCurrency { get; init; }

    /// <summary>1 Official, 2 Non-official, 3 Market — which rate table the rate came from.</summary>
    public byte RateType { get; init; }

    /// <summary>1 base currency unit = ExchangeRate invoice currency units. Exactly 1 on a base-currency invoice.</summary>
    public decimal ExchangeRate { get; init; }

    public string? BaseCurrencyCode { get; init; }

    public string? ReferenceNo { get; init; }
    public string? Notes { get; init; }
    public string Status { get; init; } = StockDocumentStatus.Draft;

    public int TotalItems { get; init; }
    public decimal TotalQuantity { get; init; }
    public decimal Subtotal { get; init; }
    public decimal TotalDiscount { get; init; }
    public decimal TotalAmount { get; init; }
    public decimal TotalAmountBase { get; init; }

    /// <summary>Cost of the goods that left, in the base currency. Set on posting; null without sales.profit.view.</summary>
    public decimal? TotalCostBase { get; init; }

    /// <summary>Net sales less cost of sales, in the base currency. Null on a draft and for a reader without sales.profit.view.</summary>
    public decimal? TotalGrossProfitBase { get; init; }

    /// <summary>The same as a percentage of the invoice's base total.</summary>
    public decimal? TotalGrossProfitPct { get; init; }

    /// <summary>The invoice a return was created from (SRET), by id and by number.</summary>
    public int? SourceDocumentId { get; init; }

    public string? SourceDocumentNumber { get; init; }

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

    /* What the DOCUMENT allows, from its status. Whether this user may is a permission, checked
       separately; both have to be true before a button is offered. Same rule as the stock documents. */
    public bool CanEdit => Status == StockDocumentStatus.Draft;
    public bool CanPost => Status == StockDocumentStatus.Draft;
    public bool CanCancel => Status == StockDocumentStatus.Posted;
    public bool CanDelete => Status == StockDocumentStatus.Draft;

    /// <summary>A posted invoice with something still not returned becomes a sales return draft.</summary>
    public bool CanCreateReturn
        => DocumentTypeCode == SalesDocumentTypes.Invoice
           && Status == StockDocumentStatus.Posted
           && Lines.Any(l => l.RemainingBase > 0);

    public IReadOnlyList<SalesInvoiceLineDto> Lines { get; init; } = [];
    public IReadOnlyList<SalesInvoiceFileDto> Files { get; init; } = [];
    public IReadOnlyList<SalesInvoiceAuditDto> Audit { get; init; } = [];
}

/// <summary>Make the sales return of a posted invoice.</summary>
public sealed class CreateSalesReturnRequest
{
    /// <summary>Null = today.</summary>
    public DateOnly? DocumentDate { get; init; }
}

/// <summary>
/// What the rate for a price list's currency would be on a date — what the page pre-fills before an
/// invoice exists.
///
/// RATE IS NULL WHEN THERE IS NONE, and that is an answer rather than a failure: the page shows a
/// warning and lets the operator type one. A base-currency list always answers 1.
/// </summary>
public sealed class RateResolutionDto
{
    public int PriceListId { get; init; }
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public string? Symbol { get; init; }
    public byte DecimalPlaces { get; init; }
    public bool IsBaseCurrency { get; init; }
    public byte RateType { get; init; }
    public decimal? Rate { get; init; }
    public DateTime? RateDate { get; init; }
    public string? BaseCurrencyCode { get; init; }
}

/// <summary>
/// What the Import Sales page gets back once its lines are posted: the invoice's identity, its
/// totals in both currencies, and how many ledger rows were written.
///
/// A SUMMARY RATHER THAN THE WHOLE INVOICE, on purpose. The page has no invoice screen to open —
/// it shows a success panel and offers to start over — so everything it prints is here and nothing
/// it would have to ignore. The full document is one GET away for the screen that will want it.
/// </summary>
public sealed class ImportPostResult
{
    public int Id { get; init; }
    public string DocumentNumber { get; init; } = string.Empty;
    public int TotalItems { get; init; }
    public decimal TotalQuantity { get; init; }
    public decimal Subtotal { get; init; }
    public decimal TotalDiscount { get; init; }
    public decimal TotalAmount { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public string? CurrencySymbol { get; init; }
    public byte DecimalPlaces { get; init; }
    public decimal TotalAmountBase { get; init; }
    public string? BaseCurrencyCode { get; init; }
    public decimal ExchangeRate { get; init; }
    public DateTime? PostedAtUtc { get; init; }

    /// <summary>One ledger row per line: how many rows the posting wrote to inventory.StockMovements.</summary>
    public int MovementsWritten { get; init; }
}

/* ── requests ──────────────────────────────────────────────────────────────────────────────── */

public sealed class SaveSalesInvoiceLineRequest
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

    /// <summary>
    /// A manual price, per unit, in the invoice currency.
    ///
    /// HONOURED ONLY FOR A CALLER HOLDING sales.invoices.priceoverride. Anybody else gets the price
    /// list price whatever they send — silently, by design: the procedure re-resolves every line, so
    /// the request cannot be the authority on what the customer is charged.
    /// </summary>
    [Range(0, double.MaxValue)]
    public decimal? UnitPrice { get; init; }

    /// <summary>0 to 100; the real ceiling is Sales:MaxDiscountPercent and the procedure enforces it.</summary>
    [Range(0, 100)]
    public decimal? DiscountPercent { get; init; }

    /// <summary>The Excel row this line came from, kept so the grid can point back at the file.</summary>
    public int? ImportRowNumber { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }
}

/// <summary>Creating or replacing a draft invoice. The lines are a full replace, as on every document.</summary>
public sealed class SaveSalesInvoiceRequest
{
    [Required]
    public DateOnly DocumentDate { get; init; }

    public DateOnly? DueDate { get; init; }

    [Range(1, int.MaxValue)]
    public int BranchId { get; init; }

    /// <summary>
    /// Optional. The warehouse now lives on each LINE; the header keeps one only so that document
    /// lists, filters, reports and exports have one to show. Null = the first line's warehouse.
    /// </summary>
    public int? WarehouseId { get; init; }

    [Range(1, int.MaxValue)]
    public int ClientId { get; init; }

    public int? SalesmanId { get; init; }

    [Range(1, int.MaxValue)]
    public int PriceListId { get; init; }

    /// <summary>1 Official (default), 2 Non-official, 3 Market.</summary>
    [Range(1, 3)]
    public byte RateType { get; init; } = RateTypes.Official;

    /// <summary>Null: the procedure takes the rate from Master Data for the document date. A value overrides it.</summary>
    [Range(0.000001, double.MaxValue)]
    public decimal? ExchangeRate { get; init; }

    [StringLength(100)]
    public string? ReferenceNo { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    public IReadOnlyList<SaveSalesInvoiceLineRequest> Lines { get; init; } = [];

    /// <summary>
    /// The client's draft id, sent on the FIRST save only.
    ///
    /// Excel imports run before the invoice exists log themselves under this reference; the save
    /// hands it to the procedure, which stamps those log rows with the new invoice's id. Meaningless
    /// on an update — the invoice has an id by then, and the wizard logs against it directly.
    /// </summary>
    [StringLength(50)]
    public string? DraftReference { get; init; }

    public string? RowVersion { get; init; }
}

/// <summary>
/// An imported file becoming ONE invoice: the header it takes, and the lines — each keeping the
/// warehouse the file named on it, so the invoice may span several. The draft reference goes on that
/// invoice, so the import logs written before it existed are attached to it as its "Imported" row.
/// </summary>
public sealed class ImportCreateSalesInvoicesRequest
{
    [Required]
    public DateOnly DocumentDate { get; init; }

    public DateOnly? DueDate { get; init; }

    [Range(1, int.MaxValue)]
    public int BranchId { get; init; }

    [Range(1, int.MaxValue)]
    public int ClientId { get; init; }

    public int? SalesmanId { get; init; }

    [Range(1, int.MaxValue)]
    public int PriceListId { get; init; }

    [Range(1, 3)]
    public byte RateType { get; init; } = RateTypes.Official;

    [Range(0.000001, double.MaxValue)]
    public decimal? ExchangeRate { get; init; }

    [StringLength(100)]
    public string? ReferenceNo { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    [StringLength(50)]
    public string? DraftReference { get; init; }

    public IReadOnlyList<Model.DTOs.Documents.ImportCreateLine> Lines { get; init; } = [];

    /// <summary>True posts each created invoice at once; a refused posting leaves that one as a draft.</summary>
    public bool PostImmediately { get; init; }
}

public sealed class PostSalesInvoiceRequest
{
    public string? RowVersion { get; init; }
}

public sealed class CancelSalesInvoiceRequest
{
    [Required]
    [StringLength(300, MinimumLength = 1)]
    public string Reason { get; init; } = string.Empty;

    public string? RowVersion { get; init; }
}

public sealed class SalesInvoiceQuery
{
    public string? Search { get; init; }
    public int? BranchId { get; init; }
    public int? WarehouseId { get; init; }
    public int? ClientId { get; init; }
    public int? SalesmanId { get; init; }

    /// <summary>Draft | Posted | Cancelled, or null for all.</summary>
    public string? Status { get; init; }

    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }
    public string SortBy { get; init; } = "DocumentDate";
    public string SortDir { get; init; } = "desc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}
