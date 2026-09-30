using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Documents;

/// <summary>
/// One validated wizard row, as every family's import-create endpoint takes it.
///
/// THE WAREHOUSE IS ON THE LINE and stays there: a file names a warehouse per row, and the rows
/// become ONE document whose lines each keep their own. Price and discount are carried for the
/// families that price (sales, purchase); a stock document reads <see cref="UnitPrice"/> as the unit
/// cost and ignores the discount.
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

/// <summary>The document the import created — one, however many warehouses the file named.</summary>
public sealed class ImportCreateDocument
{
    public int Id { get; init; }
    public string? DocumentNumber { get; init; }

    /// <summary>The document's own (header) warehouse — the first line's. The lines may name others.</summary>
    public int WarehouseId { get; init; }

    public string WarehouseName { get; init; } = string.Empty;

    /// <summary>How many distinct warehouses the lines name. More than 1 is a mixed document.</summary>
    public int WarehouseCount { get; init; }

    public int LineCount { get; init; }

    /// <summary>Draft | Posted — Draft when posting was not asked for, or was refused (see Failed).</summary>
    public string Status { get; init; } = string.Empty;
}

/// <summary>The document could not be created, or was created but refused posting.</summary>
public sealed class ImportCreateFailure
{
    /// <summary>The document's header warehouse. Null when it was never created and has none.</summary>
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
/// STILL LISTS, THOUGH THE IMPORT NOW MAKES ONE DOCUMENT. The shape is shared by the three families
/// and by the page that reads it, and a create that fails outright returns no document and one
/// failure — so the lists stay, holding at most one each.
/// </summary>
public sealed class ImportCreateResult
{
    public IReadOnlyList<ImportCreateDocument> Documents { get; init; } = [];
    public int Created { get; init; }
    public int Posted { get; init; }
    public IReadOnlyList<ImportCreateFailure> Failed { get; init; } = [];
}
