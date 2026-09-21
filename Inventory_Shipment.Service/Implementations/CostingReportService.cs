using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;

namespace Inventory_Shipment.Service.Implementations;

public sealed class CostingReportService : ICostingReportService
{
    private const string ForbiddenCode = "FORBIDDEN";

    private readonly ICostingReportRepository _reports;
    private readonly IWarehouseRepository _warehouses;
    private readonly TimeProvider _clock;

    public CostingReportService(
        ICostingReportRepository reports, IWarehouseRepository warehouses, TimeProvider clock)
    {
        _reports = reports;
        _warehouses = warehouses;
        _clock = clock;
    }

    private static Result<T> Forbidden<T>(string permission)
        => Result<T>.Failure(ErrorType.Forbidden, $"This action needs the {permission} permission.", ForbiddenCode);

    /* ── stock valuation ──────────────────────────────────────────────────────────────────────── */

    public async Task<Result<InventoryValuationResult>> ValuationAsync(
        int? warehouseId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.ItemsView))
        {
            return Forbidden<InventoryValuationResult>(Permissions.Inventory.ItemsView);
        }

        var rows = await _reports.ValuationAsync(warehouseId, cancellationToken);

        string? warehouseName = null;
        if (warehouseId is { } id)
        {
            // The name from the rows when there are any, else from the lookup: an empty warehouse
            // still has a name, and a page that says "Stock in —" reads as a bug.
            warehouseName = rows.FirstOrDefault()?.WarehouseName
                            ?? (await _warehouses.LookupAsync(false, null, id, cancellationToken)).FirstOrDefault(w => w.Id == id)?.WarehouseName;
        }

        return Result<InventoryValuationResult>.Success(new InventoryValuationResult
        {
            Items = rows,
            ItemsWithStock = rows.Count(r => r.OnHandBase != 0),
            TotalOnHandBase = rows.Sum(r => r.OnHandBase),
            TotalInventoryValue = rows.Sum(r => r.InventoryValue),
            WarehouseId = warehouseId,
            WarehouseName = warehouseName,
        });
    }

    public async Task<Result<(byte[] Content, string FileName)>> ExportValuationAsync(
        int? warehouseId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var read = await ValuationAsync(warehouseId, permissions, cancellationToken);
        if (read.IsFailure || read.Value is null)
        {
            return Result<(byte[], string)>.Failure(read.ErrorType, read.Error ?? string.Empty, read.Code ?? "ERROR");
        }

        var stamp = _clock.GetUtcNow().ToString("yyyyMMdd");
        return Result<(byte[], string)>.Success((BuildValuationWorkbook(read.Value), $"StockValuation_{stamp}.xlsx"));
    }

    private static byte[] BuildValuationWorkbook(InventoryValuationResult result)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Stock Valuation");

        sheet.Cell(1, 1).Value = result.WarehouseName is null ? "Stock Valuation - all warehouses" : $"Stock Valuation - {result.WarehouseName}";
        sheet.Cell(1, 1).Style.Font.Bold = true;
        sheet.Cell(1, 1).Style.Font.FontSize = 14;

        var row = 3;
        string[] columns = result.WarehouseId is null
            ? ["Item Code", "Item Name", "On Hand", "Average Cost", "Inventory Value"]
            : ["Item Code", "Item Name", "Warehouse", "On Hand", "Average Cost", "Inventory Value"];
        WriteHeader(sheet, row, columns);

        var firstRow = row + 1;
        foreach (var item in result.Items)
        {
            row++;
            var column = 1;
            sheet.Cell(row, column++).Value = item.ItemCode;
            sheet.Cell(row, column++).Value = item.ItemName;
            if (result.WarehouseId is not null)
            {
                sheet.Cell(row, column++).Value = item.WarehouseName ?? string.Empty;
            }

            sheet.Cell(row, column++).Value = item.OnHandBase;
            sheet.Cell(row, column++).Value = item.AverageCost is { } average ? average : Blank.Value;
            sheet.Cell(row, column).Value = item.InventoryValue;
        }

        var quantityColumn = result.WarehouseId is null ? 3 : 4;
        if (result.Items.Count > 0)
        {
            sheet.Range(firstRow, quantityColumn, row, quantityColumn).Style.NumberFormat.Format = "#,##0";
            sheet.Range(firstRow, quantityColumn + 1, row, quantityColumn + 2).Style.NumberFormat.Format = "#,##0.00";
        }

        row += 2;
        sheet.Cell(row, quantityColumn - 1).Value = "Total";
        sheet.Cell(row, quantityColumn - 1).Style.Font.Bold = true;
        sheet.Cell(row, quantityColumn).Value = result.TotalOnHandBase;
        sheet.Cell(row, quantityColumn).Style.NumberFormat.Format = "#,##0";
        sheet.Cell(row, quantityColumn + 2).Value = result.TotalInventoryValue;
        sheet.Cell(row, quantityColumn + 2).Style.NumberFormat.Format = "#,##0.00";
        sheet.Cell(row, quantityColumn + 2).Style.Font.Bold = true;

        sheet.Columns().AdjustToContents();
        sheet.Column(2).Width = 40;

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    /* ── sales profit ─────────────────────────────────────────────────────────────────────────── */

    public async Task<Result<IReadOnlyList<SalesProfitRowDto>>> SalesProfitAsync(
        SalesProfitQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Sales.ProfitView))
        {
            return Forbidden<IReadOnlyList<SalesProfitRowDto>>(Permissions.Sales.ProfitView);
        }

        if (SalesProfitGroupings.Normalize(query.GroupBy) is null)
        {
            return Result<IReadOnlyList<SalesProfitRowDto>>.Failure(
                ErrorType.Validation,
                "groupBy must be Invoice, Item, Family, Brand, Client, Salesman, Branch, Month or All.", "VALIDATION");
        }

        if (query.DateFrom is { } from && query.DateTo is { } to && from > to)
        {
            return Result<IReadOnlyList<SalesProfitRowDto>>.Failure(
                ErrorType.Validation, "The start date is after the end date.", "VALIDATION");
        }

        return Result<IReadOnlyList<SalesProfitRowDto>>.Success(await _reports.SalesProfitAsync(query, cancellationToken));
    }

    public async Task<Result<(byte[] Content, string FileName)>> ExportSalesProfitAsync(
        SalesProfitQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var read = await SalesProfitAsync(query, permissions, cancellationToken);
        if (read.IsFailure || read.Value is null)
        {
            return Result<(byte[], string)>.Failure(read.ErrorType, read.Error ?? string.Empty, read.Code ?? "ERROR");
        }

        var stamp = _clock.GetUtcNow().ToString("yyyyMMdd");
        var grouping = SalesProfitGroupings.Normalize(query.GroupBy) ?? SalesProfitGroupings.Invoice;
        return Result<(byte[], string)>.Success((BuildProfitWorkbook(read.Value, query, grouping), $"SalesProfit_{grouping}_{stamp}.xlsx"));
    }

    /// <summary>
    /// The report as it is read on screen, with the period in the header block: a profit figure
    /// without the dates it covers is not a figure anybody can file.
    /// </summary>
    private static byte[] BuildProfitWorkbook(
        IReadOnlyList<SalesProfitRowDto> rows, SalesProfitQuery query, string grouping)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Sales Profit");

        sheet.Cell(1, 1).Value = $"Sales Profit by {grouping}";
        sheet.Cell(1, 1).Style.Font.Bold = true;
        sheet.Cell(1, 1).Style.Font.FontSize = 14;
        sheet.Cell(2, 1).Value =
            $"Period: {(query.DateFrom is { } f ? f.ToString("dd/MM/yyyy") : "from the beginning")} to {(query.DateTo is { } t ? t.ToString("dd/MM/yyyy") : "today")}. Amounts in the base currency.";

        var row = 4;
        string[] columns =
            [grouping, "Invoices", "Returns", "Qty", "Gross Sales", "Discount", "Net Sales", "COGS", "Gross Profit", "GP %", "COGS adjustments"];
        WriteHeader(sheet, row, columns);

        var firstRow = row + 1;
        foreach (var item in rows)
        {
            row++;
            sheet.Cell(row, 1).Value = item.GroupLabel;
            sheet.Cell(row, 2).Value = item.InvoiceCount;
            sheet.Cell(row, 3).Value = item.ReturnCount;
            sheet.Cell(row, 4).Value = item.QuantityBase;
            sheet.Cell(row, 5).Value = item.GrossSalesBase;
            sheet.Cell(row, 6).Value = item.DiscountBase;
            sheet.Cell(row, 7).Value = item.NetSalesBase;
            sheet.Cell(row, 8).Value = item.CogsBase;
            sheet.Cell(row, 9).Value = item.GrossProfitBase;
            sheet.Cell(row, 10).Value = item.GrossProfitPct is { } pct ? pct : Blank.Value;
            sheet.Cell(row, 11).Value = item.CogsAdjustmentsBase;
        }

        if (rows.Count > 0)
        {
            sheet.Range(firstRow, 2, row, 4).Style.NumberFormat.Format = "#,##0";
            sheet.Range(firstRow, 5, row, 9).Style.NumberFormat.Format = "#,##0.00";
            sheet.Range(firstRow, 10, row, 10).Style.NumberFormat.Format = "0.00";
            sheet.Range(firstRow, 11, row, 11).Style.NumberFormat.Format = "#,##0.00";
        }

        row += 2;
        sheet.Cell(row, 1).Value = "Total";
        sheet.Cell(row, 1).Style.Font.Bold = true;
        sheet.Cell(row, 7).Value = rows.Sum(r => r.NetSalesBase);
        sheet.Cell(row, 8).Value = rows.Sum(r => r.CogsBase);
        sheet.Cell(row, 9).Value = rows.Sum(r => r.GrossProfitBase);
        sheet.Cell(row, 11).Value = rows.Sum(r => r.CogsAdjustmentsBase);
        sheet.Range(row, 7, row, 11).Style.NumberFormat.Format = "#,##0.00";
        sheet.Range(row, 7, row, 11).Style.Font.Bold = true;

        sheet.Columns().AdjustToContents();
        sheet.Column(1).Width = 40;

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private static void WriteHeader(IXLWorksheet sheet, int row, string[] columns)
    {
        for (var i = 0; i < columns.Length; i++)
        {
            sheet.Cell(row, i + 1).Value = columns[i];
        }

        var range = sheet.Range(row, 1, row, columns.Length);
        range.Style.Font.Bold = true;
        range.Style.Fill.BackgroundColor = XLColor.FromArgb(0xE8, 0xEE, 0xF7);
        range.Style.Border.BottomBorder = XLBorderStyleValues.Thin;
    }
}
