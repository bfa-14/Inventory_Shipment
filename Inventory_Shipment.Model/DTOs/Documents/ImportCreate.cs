using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Documents;

/// <summary>
/// One validated wizard row, as every family's import-create endpoint takes it.
///
/// THE WAREHOUSE IS ON THE LINE because that is what the grouping is about: a file names a warehouse
/// per row, one document holds one warehouse, so the server sorts the rows into documents by it.
/// Price and discount are carried for the families that price (sales, purchase); a stock document
/// reads <see cref="UnitPrice"/> as the unit cost and ignores the discount.
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

/// <summary>One document the import created — one per warehouse found in the file.</summary>
public sealed class ImportCreateDocument
{
    public int Id { get; init; }
    public string? DocumentNumber { get; init; }
    public int WarehouseId { get; init; }
    public string WarehouseName { get; init; } = string.Empty;
    public int LineCount { get; init; }

    /// <summary>Draft | Posted — Draft when posting was not asked for, or was refused (see Failed).</summary>
    public string Status { get; init; } = string.Empty;
}

/// <summary>A warehouse whose document could not be created, or was created but refused posting.</summary>
public sealed class ImportCreateFailure
{
    public int WarehouseId { get; init; }
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
/// </summary>
public sealed class ImportCreateResult
{
    public IReadOnlyList<ImportCreateDocument> Documents { get; init; } = [];
    public int Created { get; init; }
    public int Posted { get; init; }
    public IReadOnlyList<ImportCreateFailure> Failed { get; init; } = [];
}
