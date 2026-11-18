using System.Text.Json.Serialization;

namespace Inventory_Shipment.Model.DTOs.Dashboard;

/// <summary>
/// The query of GET api/dashboard/summary. The period is the reader's: the page works out "this month"
/// in the reader's calendar and sends the dates. The previous period defaults to the same number of days
/// just before <see cref="From"/>; Today defaults to the server's date.
/// </summary>
public sealed class DashboardSummaryQuery
{
    public int? BranchId { get; init; }
    public DateTime? From { get; init; }
    public DateTime? To { get; init; }
    public DateTime? PrevFrom { get; init; }
    public DateTime? PrevTo { get; init; }
    public DateTime? Today { get; init; }
}

/// <summary>
/// Everything the Dashboard shows, for one branch (or all) and one period. A section is NULL when the
/// reader may not open the screen its figures come from, so the page simply leaves that widget out.
/// Money is in the base currency.
/// </summary>
public sealed class DashboardSummaryDto
{
    public DateTime From { get; init; }
    public DateTime To { get; init; }
    public DateTime PrevFrom { get; init; }
    public DateTime PrevTo { get; init; }
    public DateTime Today { get; init; }
    /// <summary>The currency every amount is in.</summary>
    public string? BaseCurrencyCode { get; init; }

    public DashboardSalesDto? Sales { get; set; }
    public DashboardReceivablesDto? Receivables { get; set; }
    public DashboardPayablesDto? Payables { get; set; }
    public DashboardInventoryDto? Inventory { get; set; }
    public DashboardOnTheWayDto? OnTheWay { get; set; }
    public IReadOnlyList<DashboardDraftDto> Drafts { get; set; } = [];
    public DashboardStockAlertsDto? StockAlerts { get; set; }
    public IReadOnlyList<DashboardBelowMinimumDto>? BelowMinimum { get; set; }
    public DashboardContainersDto? Containers { get; set; }
    public IReadOnlyList<DashboardContainerDto>? ContainerList { get; set; }
    public IReadOnlyList<DashboardOverdueInvoiceDto>? OverdueInvoices { get; set; }
    public DashboardChequesDto? Cheques { get; set; }
    public IReadOnlyList<DashboardChequeDto>? ChequeList { get; set; }

    /* the charts */
    public IReadOnlyList<DashboardTrendMonthDto>? Trend { get; set; }
    public IReadOnlyList<DashboardSliceDto>? SalesByFamily { get; set; }
    public IReadOnlyList<DashboardSliceDto>? StockByWarehouse { get; set; }
    public IReadOnlyList<DashboardWeekdayDto>? SalesByWeekday { get; set; }

    /* (115) the cards: reporting.usp_Dashboard_Cards */
    /// <summary>Containers by shipment stage. Null without View Containers.</summary>
    public IReadOnlyList<DashboardStageDto>? ContainerStages { get; set; }

    /// <summary>What we owe, by payment status. Null when the reader may see neither half.</summary>
    public DashboardPayablesDetailDto? PayablesDetail { get; set; }

    /// <summary>The five creditors owed the most, on the halves the reader may see.</summary>
    public IReadOnlyList<DashboardCreditorDto>? Creditors { get; set; }

    /// <summary>What customers owe, by how late it is. Null as <see cref="Receivables"/>.</summary>
    public DashboardReceivablesAgingDto? ReceivablesAging { get; set; }

    /// <summary>The five customers owing the most. Null as <see cref="Receivables"/>.</summary>
    public IReadOnlyList<DashboardDebtorDto>? Debtors { get; set; }

    /// <summary>The twelve months to the period's end: invoiced, received, container charges. Null when none may be seen.</summary>
    public IReadOnlyList<DashboardPurchaseMonthDto>? PurchasesByMonth { get; set; }
}

/// <summary>
/// (115) One shipment stage (script 111) and the containers at it. FilterId is the Containers list's Stage filter (a
/// stage's Id, 0 Pending, -1 not on a stage; null: received without an Offload stage, no filter). Open = not delivered
/// yet; ToReceive = delivered to its Offload stage, its goods receipt not posted; Received = received in the period.
/// </summary>
public sealed class DashboardStageDto
{
    public int? FilterId { get; set; }
    public string StageName { get; set; } = string.Empty;
    /// <summary>0 Pending, 1 Leg, 2 Arrive, 3 Offload; null: not on a stage.</summary>
    public byte? StageKind { get; set; }
    public int OpenContainers { get; set; }
    public int OpenPieces { get; set; }
    public int ToReceiveContainers { get; set; }
    public int ToReceivePieces { get; set; }
    public int ReceivedContainers { get; set; }
    public int ReceivedPieces { get; set; }
}

/// <summary>
/// (115) What we still owe, by payment status: posted supplier invoices (null without View Supplier Payments or View
/// Purchase Invoices) and posted container charges (null without View Supplier Payments or View Container Charges).
/// </summary>
public sealed class DashboardPayablesDetailDto
{
    public int? UnpaidInvoiceCount { get; set; }
    public decimal? UnpaidInvoicesBase { get; set; }
    public int? PartialInvoiceCount { get; set; }
    public decimal? PartialInvoicesBase { get; set; }
    public int? UnpaidChargeCount { get; set; }
    public decimal? UnpaidChargesBase { get; set; }
    public int? PartialChargeCount { get; set; }
    public decimal? PartialChargesBase { get; set; }
}

/// <summary>(115) A supplier or charge provider we owe (PartyId null: charges without a provider).</summary>
public sealed class DashboardCreditorDto
{
    public int? PartyId { get; set; }
    public string PartyName { get; set; } = string.Empty;
    public decimal InvoicesBase { get; set; }
    public int InvoiceCount { get; set; }
    public decimal ChargesBase { get; set; }
    public int ChargeCount { get; set; }
}

/// <summary>(115) Posted sales invoices still owed, by days past their due date on the reader's today.</summary>
public sealed class DashboardReceivablesAgingDto
{
    public int NotDueCount { get; set; }
    public decimal NotDueBase { get; set; }
    public int Days1To30Count { get; set; }
    public decimal Days1To30Base { get; set; }
    public int Days31To60Count { get; set; }
    public decimal Days31To60Base { get; set; }
    public int Days61To90Count { get; set; }
    public decimal Days61To90Base { get; set; }
    public int Over90Count { get; set; }
    public decimal Over90Base { get; set; }
    public int DebtorCount { get; set; }
}

/// <summary>(115) A customer who owes.</summary>
public sealed class DashboardDebtorDto
{
    public int ClientId { get; set; }
    public string ClientName { get; set; } = string.Empty;
    public decimal OutstandingBase { get; set; }
    public decimal OverdueBase { get; set; }
    public int InvoiceCount { get; set; }
    public DateTime? OldestDueDate { get; set; }
}

/// <summary>
/// (115) One month of purchases. Invoiced: supplier invoices less returns (View Purchase Invoices). Received: posted
/// goods receipts - their pieces with View Goods Receipts, their value also with View item costs. Charges: container
/// charges posted (View Container Charges). Each null when the reader may not see it.
/// </summary>
public sealed class DashboardPurchaseMonthDto
{
    public DateTime MonthStart { get; set; }
    public decimal? InvoicedBase { get; set; }
    public decimal? ReceivedBase { get; set; }
    public int? ReceivedPieces { get; set; }
    public decimal? ChargesBase { get; set; }
}

/// <summary>One month of the twelve-month trend. Each figure is NULL when the reader may not see it.</summary>
public sealed class DashboardTrendMonthDto
{
    public DateTime MonthStart { get; set; }
    public decimal? SalesBase { get; set; }
    public decimal? GrossProfitBase { get; set; }
    public decimal? PurchasesBase { get; set; }
}

/// <summary>One slice of a donut: the five largest, then "Other".</summary>
public sealed class DashboardSliceDto
{
    public string Label { get; set; } = string.Empty;
    public decimal ValueBase { get; set; }
}

/// <summary>Sales in the period on one day of the week (1 = Monday).</summary>
public sealed class DashboardWeekdayDto
{
    public int DayNo { get; set; }
    public int InvoiceCount { get; set; }
    public decimal SalesBase { get; set; }
}

/// <summary>Posted sales invoices less posted sales returns. Gross profit is NULL without the Sales Profit permission.</summary>
public sealed class DashboardSalesDto
{
    public decimal SalesBase { get; set; }
    public decimal? GrossProfitBase { get; set; }
    public int InvoiceCount { get; set; }
    public decimal PrevSalesBase { get; set; }
    public decimal? PrevGrossProfitBase { get; set; }
}

/// <summary>What customers still owe on posted invoices, as of today.</summary>
public sealed class DashboardReceivablesDto
{
    public decimal OutstandingBase { get; set; }
    public decimal OverdueBase { get; set; }
    public int OpenCount { get; set; }
    public int OverdueCount { get; set; }
}

/// <summary>What we still owe. Each half is NULL when the reader may not see it.</summary>
public sealed class DashboardPayablesDto
{
    public decimal? InvoicesBase { get; set; }
    public int? InvoiceCount { get; set; }
    public decimal? ChargesBase { get; set; }
    public int? ChargeCount { get; set; }
}

/// <summary>Stock on hand at the items' moving average cost.</summary>
public sealed class DashboardInventoryDto
{
    /// <summary>(94) Null without View item costs (the item count stays).</summary>
    public decimal? ValueBase { get; set; }
    public int ItemsInStock { get; set; }
}

/// <summary>
/// What is still to receive (script 72), in the parts of the "Outstanding order" and "Transit" of Shortages: pieces still
/// to receive on approved orders, on posted invoices without an order, and in containers between the ship and the
/// warehouse. Each part is null for a reader who may not open the screen it comes from.
/// </summary>
public sealed class DashboardOnTheWayDto
{
    /// <summary>The orders' still to receive less the pieces travelling in containers (<see cref="InTransitPieces"/> counts those).</summary>
    public int? OnOrderPieces { get; set; }

    public int? OpenOrders { get; set; }

    /// <summary>Posted invoices WITHOUT an order whose goods are not received yet: since the switch they wait for a goods receipt.</summary>
    public int? InvoicedNotReceivedPieces { get; set; }

    public int? InTransitPieces { get; set; }
    public int? ContainersInTransit { get; set; }

    /// <summary>
    /// The orders' still to receive WITH the pieces travelling: what <see cref="OnOrderPieces"/> becomes for a reader
    /// who may not see the containers, so those pieces do not vanish with <see cref="InTransitPieces"/>. Server only.
    /// </summary>
    [JsonIgnore]
    public int? OutstandingPieces { get; set; }
}

/// <summary>Documents saved but not posted, per document type (Kind: Sales, Purchase, Inventory, Receipt, Payment).</summary>
public sealed class DashboardDraftDto
{
    public string Kind { get; set; } = string.Empty;
    public string TypeCode { get; set; } = string.Empty;
    public int DraftCount { get; set; }
}

public sealed class DashboardStockAlertsDto
{
    public int BelowMinimum { get; set; }
    public int NegativeStock { get; set; }
    /// <summary>NULL without the Out-of-Stock Sales permission.</summary>
    public int? OutOfStockSales { get; set; }

    /// <summary>
    /// (91) "Warehouse levels below Min": the stock levels per warehouse (active item, active warehouse) whose Projected is
    /// below their Min - the Stock Levels page's "Below Min" tile for the same branch (reporting.usp_Dashboard_StockLevels).
    /// NULL without View Stock Levels.
    /// </summary>
    public int? BelowWarehouseMin { get; set; }
}

public sealed class DashboardBelowMinimumDto
{
    public int ItemId { get; set; }
    public string ItemCode { get; set; } = string.Empty;
    public string ItemName { get; set; } = string.Empty;
    public int OnHand { get; set; }
    public int MinQuantity { get; set; }
    public int Missing { get; set; }
}

public sealed class DashboardContainersDto
{
    public int ArrivingSoon { get; set; }
    public int AtPort { get; set; }
    public int NearLastFreeDay { get; set; }
}

/// <summary>A container that needs attention. Reason: ArrivingSoon, AtPort, NearLastFreeDay or PastLastFreeDay.</summary>
public sealed class DashboardContainerDto
{
    public int ContainerId { get; set; }
    public string ContainerRef { get; set; } = string.Empty;
    public string? ContainerNo { get; set; }
    public byte StatusCode { get; set; }
    public DateTime? Eta { get; set; }
    public DateTime? LastFreeDay { get; set; }
    public string Reason { get; set; } = string.Empty;
}

public sealed class DashboardOverdueInvoiceDto
{
    public int DocumentId { get; set; }
    public string? DocumentNumber { get; set; }
    public string ClientName { get; set; } = string.Empty;
    public DateTime? DueDate { get; set; }
    public int DaysOverdue { get; set; }
    public decimal OutstandingBase { get; set; }
}

/// <summary>Supplier-payment cheques not cleared yet. DueCount: those whose due date has come.</summary>
public sealed class DashboardChequesDto
{
    public int PendingCount { get; set; }
    public decimal PendingBase { get; set; }
    public int DueCount { get; set; }
}

public sealed class DashboardChequeDto
{
    public int PaymentId { get; set; }
    public string? PaymentNumber { get; set; }
    public string PayeeName { get; set; } = string.Empty;
    public string? ChequeNo { get; set; }
    public DateTime? ChequeDueDate { get; set; }
    public decimal AmountBase { get; set; }
}
