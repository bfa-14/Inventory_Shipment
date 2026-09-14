using ClosedXML.Excel;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

public sealed class ShortageService : IShortageService
{
    private readonly IShortageRepository _shortages;
    private readonly IWarehouseRepository _warehouses;
    private readonly IPurchaseDocumentService _purchases;
    private readonly TimeProvider _clock;
    private readonly ILogger<ShortageService> _logger;

    public ShortageService(
        IShortageRepository shortages, IWarehouseRepository warehouses, IPurchaseDocumentService purchases,
        TimeProvider clock, ILogger<ShortageService> logger)
    {
        _shortages = shortages;
        _warehouses = warehouses;
        _purchases = purchases;
        _clock = clock;
        _logger = logger;
    }

    public async Task<Result<IReadOnlyList<ShortageRowDto>>> ReportAsync(ShortageQuery query, CancellationToken cancellationToken = default)
    {
        var rows = await _shortages.ReportAsync(query, cancellationToken);
        return Result<IReadOnlyList<ShortageRowDto>>.Success(rows);
    }

    public async Task<Result<(byte[] Content, string FileName)>> ExportAsync(ShortageQuery query, CancellationToken cancellationToken = default)
    {
        var rows = await _shortages.ReportAsync(query, cancellationToken);
        var stamp = _clock.GetUtcNow().ToString("yyyyMMdd");
        return Result<(byte[], string)>.Success((BuildWorkbook(rows, query), $"Shortages_{stamp}.xlsx"));
    }

    /// <summary>
    /// ONE ORDER PER SUPPLIER AND WAREHOUSE, in the order the lines arrive. A supplier delivers to
    /// one place per order and an order lives in one warehouse, so two warehouses short of the same
    /// item from the same supplier are two orders, not one with two addresses. The branch is the
    /// warehouse's own — the page never has to say it, and cannot get it wrong.
    /// </summary>
    public async Task<Result<CreatePurchaseOrdersResult>> CreateOrdersAsync(
        CreatePurchaseOrdersFromShortagesRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Purchase.OrdersCreate))
        {
            return Result<CreatePurchaseOrdersResult>.Failure(
                ErrorType.Forbidden, "Creating purchase orders needs the purchase.orders.create permission.", "FORBIDDEN");
        }

        if (request.Lines.Count == 0)
        {
            return Result<CreatePurchaseOrdersResult>.Failure(ErrorType.Validation, "Select at least one line to order.", "NO_LINES");
        }

        var documentDate = request.DocumentDate ?? DateOnly.FromDateTime(_clock.GetUtcNow().UtcDateTime);
        var orders = new List<CreatedPurchaseOrderDto>();
        var failed = new List<ShortageOrderFailure>();

        foreach (var group in request.Lines.GroupBy(l => (l.SupplierId, l.WarehouseId)))
        {
            var (supplierId, warehouseId) = group.Key;

            var warehouse = await _warehouses.GetByIdAsync(warehouseId, cancellationToken);
            if (warehouse is null)
            {
                failed.Add(new ShortageOrderFailure
                {
                    SupplierId = supplierId,
                    WarehouseId = warehouseId,
                    Code = "NOT_FOUND",
                    Message = $"Warehouse {warehouseId} not found.",
                });
                continue;
            }

            var draft = new SavePurchaseDocumentRequest
            {
                DocumentTypeCode = PurchaseDocumentTypes.Order,
                DocumentDate = documentDate,
                ExpectedDate = request.ExpectedDate,
                BranchId = warehouse.BranchId,
                WarehouseId = warehouseId,
                SupplierId = supplierId,
                // Null on purpose: the supplier's currency, and the rate of the day, are the engine's to resolve.
                CurrencyId = null,
                RateType = request.RateType,
                ExchangeRate = null,
                Notes = string.IsNullOrWhiteSpace(request.Notes) ? "Created from the shortage report." : request.Notes,
                Lines = group.Select((line, index) => new SavePurchaseDocumentLineRequest
                {
                    LineNo = index + 1,
                    ItemId = line.ItemId,
                    ItemUnitId = line.ItemUnitId,
                    WarehouseId = warehouseId,
                    Quantity = line.Quantity,
                    UnitPrice = line.UnitPrice,
                    Notes = line.Notes,
                }).ToList(),
            };

            var saved = await _purchases.SaveDraftAsync(null, draft, userId, permissions, cancellationToken);
            if (saved.IsFailure || saved.Value is null)
            {
                failed.Add(new ShortageOrderFailure
                {
                    SupplierId = supplierId,
                    WarehouseId = warehouseId,
                    Code = saved.Code ?? "ERROR",
                    Message = saved.Error ?? "The purchase order could not be created.",
                });
                continue;
            }

            var order = saved.Value;
            orders.Add(new CreatedPurchaseOrderDto
            {
                Id = order.Id,
                DocumentNumber = order.DocumentNumber,
                SupplierId = order.SupplierId,
                SupplierName = order.SupplierName,
                WarehouseId = order.WarehouseId,
                WarehouseName = order.WarehouseName,
                BranchId = order.BranchId,
                BranchName = order.BranchName,
                CurrencyCode = order.CurrencyCode,
                ExchangeRate = order.ExchangeRate,
                LineCount = order.Lines.Count,
                TotalAmount = order.TotalAmount,
                Status = order.Status,
            });
        }

        _logger.LogInformation(
            "Shortage report: {Created} purchase order(s) created by user {UserId}, {Failed} refused",
            orders.Count, userId, failed.Count);

        return Result<CreatePurchaseOrdersResult>.Success(new CreatePurchaseOrdersResult
        {
            Orders = orders,
            Created = orders.Count,
            Failed = failed,
        });
    }

    /// <summary>The report as a sheet, one row per item and warehouse, the short ones first as the procedure orders them.</summary>
    private static byte[] BuildWorkbook(IReadOnlyList<ShortageRowDto> rows, ShortageQuery query)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet("Shortages");

        sheet.Cell(1, 1).Value = query.OnlyShortages ? "Shortage report — items below their minimum" : "Stock levels — every evaluated item and warehouse";
        sheet.Cell(1, 1).Style.Font.Bold = true;
        sheet.Cell(1, 1).Style.Font.FontSize = 14;
        sheet.Cell(2, 1).Value = $"Average daily sales over {query.DaysForAverage} days. Available = On Hand + Incoming (open purchase orders).";
        sheet.Cell(2, 1).Style.Font.Italic = true;

        string[] columns =
        [
            "Item Code", "Item Name", "Brand", "Family", "Branch", "Warehouse",
            "On Hand", "Incoming", "Available", "Min", "Max", "Shortage", "Suggested (base)",
            "Suggested Qty", "Purchase Unit", "Avg Daily Sales", "Days of Cover",
            "Supplier", "Default Supplier", "Last Cost", "Average Cost", "Lead Time (days)", "Last Purchase",
        ];

        const int headerRow = 4;
        for (var i = 0; i < columns.Length; i++)
        {
            sheet.Cell(headerRow, i + 1).Value = columns[i];
        }

        var headerRange = sheet.Range(headerRow, 1, headerRow, columns.Length);
        headerRange.Style.Font.Bold = true;
        headerRange.Style.Fill.BackgroundColor = XLColor.FromArgb(0xE8, 0xEE, 0xF7);
        headerRange.Style.Border.BottomBorder = XLBorderStyleValues.Thin;

        var row = headerRow;
        foreach (var r in rows)
        {
            row++;
            sheet.Cell(row, 1).Value = r.ItemCode;
            sheet.Cell(row, 2).Value = r.ItemName;
            sheet.Cell(row, 3).Value = r.BrandName;
            sheet.Cell(row, 4).Value = r.FamilyName;
            sheet.Cell(row, 5).Value = r.BranchName;
            sheet.Cell(row, 6).Value = $"{r.WarehouseCode} - {r.WarehouseName}";
            sheet.Cell(row, 7).Value = r.OnHandBase;
            sheet.Cell(row, 8).Value = r.IncomingBase;
            sheet.Cell(row, 9).Value = r.AvailableBase;
            sheet.Cell(row, 10).Value = r.MinQuantity;
            sheet.Cell(row, 11).Value = Num(r.MaxQuantity);
            sheet.Cell(row, 12).Value = r.ShortageBase;
            sheet.Cell(row, 13).Value = r.SuggestedBase;
            sheet.Cell(row, 14).Value = r.SuggestedQty;
            sheet.Cell(row, 15).Value = r.PurchaseUnitName is null
                ? string.Empty
                : r.PurchasePackingFormula > 1 ? $"{r.PurchaseUnitName} (x{r.PurchasePackingFormula})" : r.PurchaseUnitName;
            sheet.Cell(row, 16).Value = r.AvgDailySalesBase;
            sheet.Cell(row, 17).Value = Num(r.DaysOfCover);
            sheet.Cell(row, 18).Value = r.SupplierName ?? string.Empty;
            sheet.Cell(row, 19).Value = r.SupplierIsDefault ? "Yes" : "No";
            sheet.Cell(row, 20).Value = Num(r.LastCost);
            sheet.Cell(row, 21).Value = Num(r.AverageCost);
            sheet.Cell(row, 22).Value = Num(r.LeadTimeDays);
            sheet.Cell(row, 23).Value = r.LastPurchaseAtUtc?.ToString("dd/MM/yyyy") ?? string.Empty;

            if (r.ShortageBase > 0)
            {
                sheet.Range(row, 1, row, columns.Length).Style.Fill.BackgroundColor =
                    r.OnHandBase <= 0 ? XLColor.FromArgb(0xFF, 0xE3, 0xE3) : XLColor.FromArgb(0xFF, 0xF0, 0xDB);
            }
        }

        if (rows.Count > 0)
        {
            var first = headerRow + 1;
            sheet.Range(first, 7, row, 14).Style.NumberFormat.Format = "#,##0";
            sheet.Range(first, 16, row, 17).Style.NumberFormat.Format = "#,##0.00";
            sheet.Range(first, 20, row, 21).Style.NumberFormat.Format = "#,##0.0000";
        }

        sheet.Columns().AdjustToContents();
        sheet.Column(2).Width = 40;

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    /// <summary>A nullable number as a cell value: the number, or an empty cell rather than a zero that would be a lie.</summary>
    private static XLCellValue Num(decimal? value) => value.HasValue ? (XLCellValue)value.Value : Blank.Value;

    private static XLCellValue Num(int? value) => value.HasValue ? (XLCellValue)value.Value : Blank.Value;
}
