using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Dashboard;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Inventory_Shipment.Service.Security;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// The Dashboard. ONE CALL, THEN TRIMMED: the procedure computes every section, and this service
/// removes those the reader may not open on their own screen. A figure is shown to a reader only when
/// they may open the screen it comes from, so the Dashboard never tells more than the menus do.
/// </summary>
public sealed class DashboardService : IDashboardService
{
    /// <summary>The longest period the Dashboard answers for: a little over a year, so "This year" always fits.</summary>
    private const int MaxPeriodDays = 400;

    /// <summary>Which permission shows the drafts of each document type.</summary>
    private static readonly Dictionary<string, string> DraftPermissions = new(StringComparer.OrdinalIgnoreCase)
    {
        ["SINV"] = Permissions.Sales.InvoicesView,
        ["SRET"] = Permissions.Sales.InvoicesView,
        ["PO"] = Permissions.Purchase.OrdersView,
        ["PINV"] = Permissions.Purchase.InvoicesView,
        ["PRET"] = Permissions.Purchase.ReturnsView,
        ["GRN"] = Permissions.Purchase.GoodsReceiptsView,      // draft goods receipts (script 72)
        ["INV_IN"] = Permissions.Inventory.StockInView,
        ["INV_OUT"] = Permissions.Inventory.StockOutView,
        ["BIV_OUT"] = Permissions.Inventory.BivacOutView,
        ["RCPT"] = Permissions.Sales.ReceiptsView,
        ["PAY"] = Permissions.Purchase.PaymentsView,
    };

    private readonly IDashboardRepository _dashboard;

    public DashboardService(IDashboardRepository dashboard)
    {
        _dashboard = dashboard;
    }

    public async Task<Result<DashboardSummaryDto>> GetSummaryAsync(
        DashboardSummaryQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var today = (query.Today ?? DateTime.UtcNow).Date;
        var from = (query.From ?? new DateTime(today.Year, today.Month, 1)).Date;
        var to = (query.To ?? today).Date;
        if (to < from)
        {
            return Result<DashboardSummaryDto>.Failure(ErrorType.Validation, "The period ends before it starts.", "VALIDATION");
        }

        if ((to - from).TotalDays > MaxPeriodDays)
        {
            return Result<DashboardSummaryDto>.Failure(
                ErrorType.Validation, $"Choose a period of at most {MaxPeriodDays} days.", "VALIDATION");
        }

        // The period before: as given, else the same number of days just before this one.
        var prevTo = (query.PrevTo ?? from.AddDays(-1)).Date;
        var prevFrom = (query.PrevFrom ?? prevTo.AddDays(-(to - from).TotalDays)).Date;
        if (prevTo < prevFrom || (prevTo - prevFrom).TotalDays > MaxPeriodDays)
        {
            return Result<DashboardSummaryDto>.Failure(ErrorType.Validation, "The previous period is not valid.", "VALIDATION");
        }

        // (91) "Warehouse levels below Min" is read only for a reader who sees it (Trim blanks it for anybody else): it
        // reads every level of the scope, and nobody should wait for a figure they are never shown.
        var warehouseLevels = permissions.Contains(Permissions.Inventory.ItemsView)
                              && permissions.Contains(Permissions.Inventory.StockLevelsView);
        // (115) The cards are read only for a reader who may see at least one of them.
        var cards = new[]
        {
            Permissions.Containers.View, Permissions.Purchase.PaymentsView, Permissions.Purchase.InvoicesView,
            Permissions.Containers.ChargesView, Permissions.Sales.InvoicesView, Permissions.Sales.ReceiptsView,
            Permissions.Purchase.GoodsReceiptsView,
        }.Any(permissions.Contains);
        var summary = await _dashboard.GetSummaryAsync(
            query.BranchId, from, to, prevFrom, prevTo, today, warehouseLevels, cards, cancellationToken);
        Trim(summary, permissions);
        return Result<DashboardSummaryDto>.Success(summary);
    }

    /// <summary>Removes every section, and every part of a section, the reader may not see.</summary>
    private static void Trim(DashboardSummaryDto s, IReadOnlySet<string> p)
    {
        bool Has(string permission) => p.Contains(permission);

        var salesInvoices = Has(Permissions.Sales.InvoicesView);
        if (!salesInvoices)
        {
            s.Sales = null;
            s.OverdueInvoices = null;
            s.SalesByFamily = null;
            s.SalesByWeekday = null;
        }
        else if (s.Sales is not null && !Has(Permissions.Sales.ProfitView))
        {
            s.Sales.GrossProfitBase = null;
            s.Sales.PrevGrossProfitBase = null;
        }

        if (!salesInvoices && !Has(Permissions.Sales.ReceiptsView))
        {
            s.Receivables = null;
        }

        // Payables: supplier invoices and container charges are two screens; the payments screen shows both.
        var payments = Has(Permissions.Purchase.PaymentsView);
        if (s.Payables is not null)
        {
            if (!payments && !Has(Permissions.Purchase.InvoicesView))
            {
                s.Payables.InvoicesBase = null;
                s.Payables.InvoiceCount = null;
            }

            if (!payments && !Has(Permissions.Containers.ChargesView))
            {
                s.Payables.ChargesBase = null;
                s.Payables.ChargeCount = null;
            }

            if (s.Payables.InvoicesBase is null && s.Payables.ChargesBase is null)
            {
                s.Payables = null;
            }
        }

        var items = Has(Permissions.Inventory.ItemsView);
        if (!items)
        {
            s.Inventory = null;
            s.StockByWarehouse = null;
            s.StockAlerts = null;
            s.BelowMinimum = null;
        }
        else if (s.StockAlerts is not null && !Has(Permissions.Sales.OutOfStockAuditView))
        {
            s.StockAlerts.OutOfStockSales = null;
        }

        // (91) The warehouses' own levels are Stock Levels' screen: its line opens it.
        if (s.StockAlerts is not null && !Has(Permissions.Inventory.StockLevelsView))
        {
            s.StockAlerts.BelowWarehouseMin = null;
        }

        // (94) The inventory value and the value by warehouse are stock at the average cost: View item costs.
        if (!Has(Permissions.Inventory.CostsView))
        {
            ItemCosts.Strip(s);
        }

        var containers = Has(Permissions.Containers.View);
        if (s.OnTheWay is not null)
        {
            if (!Has(Permissions.Purchase.OrdersView))
            {
                s.OnTheWay.OnOrderPieces = null;
                s.OnTheWay.OpenOrders = null;
            }
            else if (!containers)
            {
                // The pieces travelling in containers are left out of the orders' figure because the in-transit figure
                // counts them. A reader who may not see that one (the Owner, for example) gets them back in the
                // orders' figure, or they would show nowhere.
                s.OnTheWay.OnOrderPieces = s.OnTheWay.OutstandingPieces;
            }

            if (!Has(Permissions.Purchase.InvoicesView))
            {
                s.OnTheWay.InvoicedNotReceivedPieces = null;
            }

            if (!containers)
            {
                s.OnTheWay.InTransitPieces = null;
                s.OnTheWay.ContainersInTransit = null;
            }

            s.OnTheWay.OutstandingPieces = null;
            if (s.OnTheWay.OnOrderPieces is null && s.OnTheWay.InvoicedNotReceivedPieces is null && s.OnTheWay.InTransitPieces is null)
            {
                s.OnTheWay = null;
            }
        }

        if (!containers)
        {
            s.Containers = null;
            s.ContainerList = null;
        }

        if (!payments)
        {
            s.Cheques = null;
            s.ChequeList = null;
        }

        // The trend: each line only for a reader who may see it; no line at all, no chart.
        var profit = salesInvoices && Has(Permissions.Sales.ProfitView);
        var purchases = Has(Permissions.Purchase.InvoicesView);
        if (s.Trend is not null)
        {
            foreach (var month in s.Trend)
            {
                if (!salesInvoices) month.SalesBase = null;
                if (!profit) month.GrossProfitBase = null;
                if (!purchases) month.PurchasesBase = null;
            }

            if (!salesInvoices && !purchases)
            {
                s.Trend = null;
            }
        }

        s.Drafts = s.Drafts
            .Where(d => DraftPermissions.TryGetValue(d.TypeCode, out var permission) && Has(permission))
            .ToList();

        TrimCards(s, p);
    }

    /// <summary>
    /// (115) The cards, by the same rules as the figures above: containers by stage with View Containers; what we owe in
    /// two halves (supplier invoices: View Supplier Payments or View Purchase Invoices; container charges: View Supplier
    /// Payments or View Container Charges), the creditors on the halves left and the five owed the most; what customers
    /// owe as "Customers owe" (View Sales Invoices or View Receipts); purchases by month line by line (invoiced: View
    /// Purchase Invoices; received: View Goods Receipts, its value also View item costs; charges: View Container
    /// Charges).
    /// </summary>
    private static void TrimCards(DashboardSummaryDto s, IReadOnlySet<string> p)
    {
        bool Has(string permission) => p.Contains(permission);

        if (!Has(Permissions.Containers.View))
        {
            s.ContainerStages = null;
        }

        var payments = Has(Permissions.Purchase.PaymentsView);
        var invoices = payments || Has(Permissions.Purchase.InvoicesView);
        var charges = payments || Has(Permissions.Containers.ChargesView);
        if (s.PayablesDetail is not null)
        {
            if (!invoices)
            {
                s.PayablesDetail.UnpaidInvoiceCount = null;
                s.PayablesDetail.UnpaidInvoicesBase = null;
                s.PayablesDetail.PartialInvoiceCount = null;
                s.PayablesDetail.PartialInvoicesBase = null;
            }

            if (!charges)
            {
                s.PayablesDetail.UnpaidChargeCount = null;
                s.PayablesDetail.UnpaidChargesBase = null;
                s.PayablesDetail.PartialChargeCount = null;
                s.PayablesDetail.PartialChargesBase = null;
            }
        }

        if (!invoices && !charges)
        {
            s.PayablesDetail = null;
            s.Creditors = null;
        }
        else if (s.Creditors is not null)
        {
            // A creditor shown only on what the reader may see, then ranked again on that: the procedure sends them all.
            s.Creditors = s.Creditors
                .Select(c =>
                {
                    if (!invoices) { c.InvoicesBase = 0; c.InvoiceCount = 0; }
                    if (!charges) { c.ChargesBase = 0; c.ChargeCount = 0; }
                    return c;
                })
                .Where(c => c.InvoiceCount + c.ChargeCount > 0)
                .OrderByDescending(c => c.InvoicesBase + c.ChargesBase)
                .ThenBy(c => c.PartyName, StringComparer.CurrentCultureIgnoreCase)
                .Take(5)
                .ToList();
        }

        if (!Has(Permissions.Sales.InvoicesView) && !Has(Permissions.Sales.ReceiptsView))
        {
            s.ReceivablesAging = null;
            s.Debtors = null;
        }

        var invoiced = Has(Permissions.Purchase.InvoicesView);
        var received = Has(Permissions.Purchase.GoodsReceiptsView);
        var receivedValue = received && Has(Permissions.Inventory.CostsView);
        var chargesPosted = Has(Permissions.Containers.ChargesView);
        if (s.PurchasesByMonth is not null)
        {
            if (!invoiced && !received && !chargesPosted)
            {
                s.PurchasesByMonth = null;
            }
            else
            {
                foreach (var month in s.PurchasesByMonth)
                {
                    if (!invoiced) month.InvoicedBase = null;
                    if (!received) month.ReceivedPieces = null;
                    if (!receivedValue) month.ReceivedBase = null;
                    if (!chargesPosted) month.ChargesBase = null;
                }
            }
        }
    }
}
