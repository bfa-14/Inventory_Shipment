using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Documents;

/// <summary>
/// One validated wizard row, as every family's import-create endpoint takes it.
///
/// THE WAREHOUSE IS ON THE LINE and stays there: a file names a warehouse per row, and by default the
/// rows become ONE document whose lines each keep their own. Sales invoices and stock documents can
/// instead be asked for one document per warehouse (SplitByWarehouse on their requests), which groups
/// the lines by this id. Price and discount are carried for the families that price (sales,
/// purchase); a stock document reads <see cref="UnitPrice"/> as the unit cost and ignores the discount.
/// </summary>
public sealed class ImportCreateLine
{
    [Range(1, int.MaxValue)]
    public int WarehouseId { get; init; }

    [Range(1, int.MaxValue)]
    public int ItemId { get; init; }

    [Range(1, int.MaxValue)]
    public int ItemUnitId { get; init; }

    [Range(1, int.MaxValue)]
    public int Quantity { get; init; }

    /// <summary>Selling price (sales), cost (inventory in / purchase), ignored on an Out.</summary>
    [Range(0, double.MaxValue)]
    public decimal? UnitPrice { get; init; }

    [Range(0, 100)]
    public decimal? DiscountPercent { get; init; }

    public DateOnly? ExpiryDate { get; init; }

    [StringLength(300)]
    public string? Notes { get; init; }

    /// <summary>The Excel row the line came from, kept so a refusal can point back at the file.</summary>
    public int? ImportRowNumber { get; init; }
}

/// <summary>
/// A document the import created: the only one, however many warehouses the file named, or one of
/// several when the file was split by warehouse (or, for supplier invoices, by item).
/// </summary>
public sealed class ImportCreateDocument
{
    public int Id { get; init; }
    public string? DocumentNumber { get; init; }

    /// <summary>
    /// The document's own (header) warehouse: the first line's on a single document, whose lines may
    /// name others; the group's own on a document split by warehouse.
    /// </summary>
    public int WarehouseId { get; init; }

    public string WarehouseName { get; init; } = string.Empty;

    /// <summary>How many distinct warehouses the lines name. More than 1 is a mixed document; always 1 when split by warehouse.</summary>
    public int WarehouseCount { get; init; }

    public int LineCount { get; init; }

    /// <summary>Draft | Posted — Draft when posting was not asked for, or was refused (see Failed).</summary>
    public string Status { get; init; } = string.Empty;

    /// <summary>A supplier invoice's item: it holds one (script 45), one invoice per item of the file. Null for the other kinds.</summary>
    public int? ItemId { get; init; }

    public string? ItemCode { get; init; }
    public string? ItemName { get; init; }

    /// <summary>
    /// Posted, but its goods receipt was not made: a supplier invoice whose type receives its goods at posting (script
    /// 79) and whose receipt the database refused - "Invoice posted; the goods receipt was not: {reason}. Use Receive
    /// goods…". Null otherwise. Not a failure: the invoice is posted, only its goods wait.
    /// </summary>
    public string? Warning { get; init; }

    /// <summary>The goods receipt made and posted with the invoice (script 79), when its type receives its goods.</summary>
    public string? GoodsReceiptNumber { get; init; }
}

/// <summary>A document could not be created, or was created but refused posting.</summary>
public sealed class ImportCreateFailure
{
    /// <summary>
    /// The document's header warehouse. On a file split by warehouse, the group's warehouse even when
    /// its document was never created; otherwise null when the document was never created and has none.
    /// </summary>
    public int? WarehouseId { get; init; }

    public string? WarehouseName { get; init; }
    public string Code { get; init; } = string.Empty;
    public string Message { get; init; } = string.Empty;
}

/// <summary>
/// The answer to an import-create: what was created, what was posted, what was refused.
///
/// A REFUSED POSTING LEAVES ITS DOCUMENT AS A DRAFT and lists it in both places — in
/// <see cref="Documents"/> with status Draft, and in <see cref="Failed"/> with the reason — so the
/// page can open it and fix it rather than lose the lines.
///
/// LISTS, BECAUSE AN IMPORT MAY MAKE ONE DOCUMENT OR SEVERAL. By default a file becomes ONE document
/// however many warehouses it names, and a create that fails outright returns no document and one
/// failure. A sales invoice or stock document import asked to split by warehouse makes one document
/// per warehouse, each created and posted on its own: every one is listed here, every refusal in
/// <see cref="Failed"/> with its warehouse. Supplier invoices hold one item (script 45), so a file of
/// several items lists one invoice per item. <see cref="Created"/> and <see cref="Posted"/> count them.
/// </summary>
public sealed class ImportCreateResult
{
    public IReadOnlyList<ImportCreateDocument> Documents { get; init; } = [];
    public int Created { get; init; }
    public int Posted { get; init; }
    public IReadOnlyList<ImportCreateFailure> Failed { get; init; } = [];
}
