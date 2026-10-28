using Inventory_Shipment.Model.DTOs.Dashboard;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.DTOs.Inventory.Shortages;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Interfaces;

namespace Inventory_Shipment.Service.Security;

/// <summary>
/// WHO MAY SEE WHAT AN ITEM COSTS (script 94). STRIPPED ON THE WAY OUT, IN ONE PLACE PER SHAPE: a figure the reader may not
/// see comes back NULL, never 0. The pages decide by the permission whether to draw the column at all.
///
/// Every shape is changed in place and returned (a record is copied with its figures null): no service caches a DTO, so
/// a stripped answer never reaches another reader. Stock Valuation, purchase documents, landed cost adjustments, container
/// charges and sales costs keep their own permissions and are not handled here.
/// </summary>
public static class ItemCosts
{
    /// <summary>Whether the reader may see item costs; null = an internal caller, which always does.</summary>
    public static bool Sees(IReadOnlySet<string>? permissions)
        => permissions is null || permissions.Contains(Permissions.Inventory.CostsView);

    /// <summary>
    /// THE TOKEN, CONFIRMED BY THE DATABASE, WHERE A HIDDEN COST COULD BE SAVED BACK WRONG: the reads and the saves of an
    /// Inventory In / Out and of a goods receipt, whose lines carry a cost the page sends back. A token says what its user
    /// could do when it was issued, up to 15 minutes ago: one issued before "View item costs" was ticked - every token of
    /// the first 15 minutes after script 94 is deployed, since none carried the code - would drop the costs a page sends
    /// and strip the draft it then saves again, so a page still showing costs (a tab running the web of before 94 among
    /// them) would lose them. So when the token lacks the code the database is asked once (security.usp_User_GetAccess,
    /// the read of the sign-in and the refresh); a token that holds it asks nothing. Only a grant is seen at once here: a
    /// permission unticked still takes effect at the next token, like every permission.
    /// </summary>
    public static async Task<IReadOnlySet<string>> ConfirmedAsync(
        IReadOnlySet<string> permissions, int? userId, IUserRepository users, CancellationToken cancellationToken)
    {
        if (Sees(permissions) || userId is not { } id)
        {
            return permissions;
        }

        var access = await users.GetAccessAsync(id, cancellationToken);
        return access.Permissions.Contains(Permissions.Inventory.CostsView, StringComparer.Ordinal)
            ? new HashSet<string>(permissions, StringComparer.Ordinal) { Permissions.Inventory.CostsView }
            : permissions;
    }

    /* ── Item Definition ──────────────────────────────────────────────────────────────────────── */

    /// <summary>A row of the item list (and of the item search behind every scan box).</summary>
    public static ItemListDto Strip(ItemListDto item)
    {
        item.AverageCost = null;
        item.LastCost = null;
        item.FobCost = null;
        item.InventoryValue = null;
        return item;
    }

    /// <summary>The item card: GET items/{id} and the answers of its create and update.</summary>
    public static ItemDetailsDto Strip(ItemDetailsDto item)
    {
        item.LastCost = null;
        item.AverageCost = null;
        item.FobCost = null;
        item.InventoryValue = null;
        item.LastPurchaseCost = null;
        return item;
    }

    /// <summary>The item's Stock Balance: each warehouse's average and value, and the total value (stripped after it is computed).</summary>
    public static ItemStockBalanceDto Strip(ItemStockBalanceDto balance)
    {
        foreach (var row in balance.Warehouses)
        {
            row.AverageCost = null;
            row.InventoryValue = null;
        }

        balance.TotalInventoryValue = null;
        return balance;
    }

    /// <summary>The item's Stock Movement: each movement's unit cost (the transfer rows included).</summary>
    public static ItemStockStatementDto Strip(ItemStockStatementDto statement)
    {
        foreach (var movement in statement.Movements)
        {
            movement.UnitCostBase = null;
        }

        return statement;
    }

    /* ── Inventory In / Out / BIVAC Out ───────────────────────────────────────────────────────── */

    public static StockDocumentListDto Strip(StockDocumentListDto row)
    {
        row.TotalCost = null;
        return row;
    }

    public static StockDocumentDto Strip(StockDocumentDto document)
    {
        document.TotalCost = null;
        foreach (var line in document.Lines)
        {
            line.UnitCost = null;
            line.LineTotal = null;
        }

        return document;
    }

    /* ── Shortages ────────────────────────────────────────────────────────────────────────────── */

    /// <summary>A live row or a plan's line: the last cost, and a live row's average cost.</summary>
    public static T Strip<T>(T row) where T : ShortageFiguresDto
    {
        row.LastCost = null;
        if (row is ShortageLiveRowDto live)
        {
            live.AverageCost = null;
        }

        return row;
    }

    /// <summary>
    /// A plan: its lines' last cost; and the totals of the purchase orders made from it unless the reader may see purchase
    /// orders (<paramref name="seesOrders"/>): a plan's order is priced at the item's last cost, so on a one-item plan its
    /// total, until a buyer reprices it, is that cost times the pieces.
    /// </summary>
    public static ShortageDocumentDto Strip(ShortageDocumentDto document, bool seesOrders = false)
    {
        foreach (var line in document.Lines)
        {
            Strip(line);
        }

        if (!seesOrders)
        {
            foreach (var order in document.PurchaseOrders)
            {
                order.TotalAmount = null;
            }
        }

        return document;
    }

    /* ── Goods receipts ───────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// A goods receipt: its values, every line's costs and value, the matches' invoice costs and the cost adjustments'
    /// figures. The source names (Order, Invoice, Manual), the pieces, the causes and the documents stay.
    /// </summary>
    public static GoodsReceiptDto Strip(GoodsReceiptDto receipt)
    {
        foreach (var line in receipt.Lines)
        {
            line.PoFobBase = null;
            line.OrderPriceBase = null;
            line.ManualUnitCostBase = null;
            line.FobCostBase = null;
            line.ChargesBase = null;
            line.UnitCostBase = null;
            line.CostAtReceiptBase = null;
            line.ValueBase = null;
        }

        foreach (var match in receipt.Matches)
        {
            match.InvoiceFobBase = null;
            match.InvoiceUnitCostBase = null;
        }

        foreach (var change in receipt.CostChanges)
        {
            change.FobBefore = null;
            change.FobAfter = null;
            change.UnitCostBefore = null;
            change.UnitCostAfter = null;
            change.AmountBase = null;
            change.InventoryBase = null;
            change.CogsBase = null;
        }

        // The history says the cost was adjusted, and by which document, as the Cost adjustments card does; the amounts
        // its sentence carries are the card's own (amount, stock, cost of sales), so they go too.
        foreach (var row in receipt.Audit)
        {
            if (string.Equals(row.Action, CostAdjustedAction, StringComparison.Ordinal))
            {
                row.Details = WithoutAmounts(row.Details);
            }
        }

        return receipt with { ValueAtReceiptBase = null, CurrentValueBase = null };
    }

    /// <summary>The goods receipt history's action for a cost adjustment (purchase.GoodsReceiptAudit, scripts 64 and 65).</summary>
    private const string CostAdjustedAction = "CostAdjusted";

    /// <summary>
    /// "Cost adjusted by PINV-BR-002-000001 (invoice posted): 400.00 (stock 400.00, cost of sales 0.00)" becomes
    /// "Cost adjusted by PINV-BR-002-000001 (invoice posted)". A sentence of another shape goes as null rather than risk a
    /// figure.
    /// </summary>
    private static string? WithoutAmounts(string? details)
    {
        var cut = details?.IndexOf("): ", StringComparison.Ordinal) ?? -1;
        return cut < 0 ? null : details![..(cut + 1)];
    }

    /// <summary>
    /// "Receive goods..." (GET goods-receipts/receivable: by order, supplier, invoice or container): each line's price per
    /// piece - the order line's, or the posted invoice line's FOB, which becomes the item's FOB cost once the goods are
    /// received. The goods receipt it makes hides the same figures; no dialog draws it.
    /// </summary>
    public static ReceivableDto Strip(ReceivableDto receivable)
    {
        foreach (var line in receivable.Lines)
        {
            line.UnitPriceBase = null;
        }

        return receivable;
    }

    public static GoodsReceiptListItemDto Strip(GoodsReceiptListItemDto row)
    {
        row.ValueBase = null;
        return row;
    }

    /// <summary>The list's totals: "Received not invoiced" keeps its pieces, not its value.</summary>
    public static GoodsReceiptListTotalsDto Strip(GoodsReceiptListTotalsDto totals)
    {
        totals.ReceivedNotInvoicedValueBase = null;
        return totals;
    }

    /* ── Dashboard ────────────────────────────────────────────────────────────────────────────── */

    /// <summary>The inventory value and the value by warehouse: stock at the average cost. The item count stays.</summary>
    public static void Strip(DashboardSummaryDto summary)
    {
        if (summary.Inventory is not null)
        {
            summary.Inventory.ValueBase = null;
        }

        summary.StockByWarehouse = null;
    }
}
