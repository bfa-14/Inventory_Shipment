namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>
/// The price a line gets from a price list — or the answer that there is none.
///
/// NULL PRICE IS AN ANSWER, NOT AN ERROR. A sales line for an item nobody has priced yet is an
/// ordinary state the page turns into a red "No price in Retail USD" and a blocked save; a 404 here
/// would make every new line a round trip that may fail, which is not what "look this up" means.
/// </summary>
public sealed class UnitPriceResolutionDto
{
    public int ItemUnitId { get; init; }
    public int PriceListId { get; init; }

    /// <summary>The price per unit in the list's currency, or null when the list has none for this unit.</summary>
    public decimal? Price { get; init; }

    /// <summary>Branch | AllBranches — which row answered; null with a null price.</summary>
    public string? Source { get; init; }

    public string? CurrencyCode { get; init; }
    public byte? DecimalPlaces { get; init; }

    /// <summary>The branch whose price it is, or "All Branches".</summary>
    public string? BranchName { get; init; }
}
