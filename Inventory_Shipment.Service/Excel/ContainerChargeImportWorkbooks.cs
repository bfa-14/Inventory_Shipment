using ClosedXML.Excel;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Service.Excel;

/// <summary>
/// The two workbooks the container charges import hands OUT: the template, and the report of the rows that
/// did not come through cleanly.
///
/// THE TEMPLATE IS WRITTEN BY THE CODE THAT READS IT, like the invoice import's: its headings are
/// <see cref="ContainerChargeImportParser.TemplateHeaders"/>, so a file filled from it always matches. Its
/// "Lists" sheet is the master data of the moment the template was downloaded: the active charge types
/// (with the allocation each one defaults to) and the active currencies.
///
/// TWO EXAMPLE ROWS, marked in their Notes, and the import refuses a row still carrying the mark: an example
/// charge left in the file can never be created on a real container.
///
/// THE ERROR REPORT IS THE FILE BACK, ANNOTATED: the template's columns as the person typed them, plus Row,
/// Status and Message, so it is corrected in Excel and uploaded again.
/// </summary>
public sealed class ContainerChargeImportWorkbooks
{
    public const string TemplateFileName = "Import_Container_Charges_Template.xlsx";
    public const string ErrorReportFileName = "Import_Container_Charges_Errors.xlsx";
    public const string ContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    /// <summary>The Notes of the template's example rows. A row whose notes start with it is refused.</summary>
    public const string ExampleMarker = "EXAMPLE ROW";

    private const string DateFormat = "dd/MM/yyyy";
    private const string AmountFormat = "#,##0.00";
    private const string RateFormat = "#,##0.######";

    /// <summary>The last template row the drop-down lists cover: the parser's row limit and the header.</summary>
    private const int ListRows = ContainerChargeImportParser.MaxDataRows + 1;

    private static readonly XLColor HeaderFill = XLColor.FromArgb(0xE8, 0xEE, 0xF7);

    /// <summary>The methods an import may use: Manual is typed line by line on a charge, never from a file.</summary>
    private static readonly (string Method, string Meaning)[] AllocationMethods =
    [
        ("Value", "By the FOB value of each item (order price, then invoice price, then the final FOB)."),
        ("Quantity", "By the pieces of each item (received once offloaded, loaded before)."),
        ("Weight", "By pieces × the item's weight (kg). Every item needs its weight to post the charge."),
        ("Volume", "By pieces × the item's volume (CBM). Every item needs its volume to post the charge."),
    ];

    /// <summary>
    /// The template: the "Charges" sheet with two example rows, "Instructions" and "Lists".
    /// </summary>
    public byte[] GenerateTemplate(
        IReadOnlyList<ChargeTypeLookupDto> chargeTypes, IReadOnlyList<CurrencyLookup> currencies, DateOnly today)
    {
        var activeTypes = chargeTypes.Where(t => t.IsActive).OrderBy(t => t.ChargeCode, StringComparer.OrdinalIgnoreCase).ToList();
        var activeCurrencies = currencies.Where(c => c.IsActive).OrderByDescending(c => c.IsBaseCurrency).ThenBy(c => c.CurrencyCode).ToList();
        var baseCode = activeCurrencies.FirstOrDefault(c => c.IsBaseCurrency)?.CurrencyCode ?? "USD";

        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet(ContainerChargeImportParser.DataSheetName);
        var headers = ContainerChargeImportParser.TemplateHeaders;

        for (var index = 0; index < headers.Length; index++)
        {
            sheet.Cell(1, index + 1).Value = headers[index];
        }

        StyleHeader(sheet.Range(1, 1, 1, headers.Length));

        // Two charges of one provider invoice on two containers (one by number, one by ref): together they
        // also show a charge group. Real charge types, those that enter the cost and are not allocated by
        // hand first, so the examples read as the usual case.
        var exampleTypes = activeTypes
            .OrderByDescending(t => t.IncludeInLandedCost)
            .ThenBy(t => string.Equals(t.AllocationMethod, ChargeAllocationMethods.Manual, StringComparison.OrdinalIgnoreCase))
            // Freight first when it exists: the charge every container has, so the example reads like a real file.
            .ThenBy(t => !t.ChargeCode.StartsWith("FRE", StringComparison.OrdinalIgnoreCase))
            .Select(t => t.ChargeCode)
            .ToList();
        var firstType = exampleTypes.ElementAtOrDefault(0) ?? "FREIGHT";
        var secondType = exampleTypes.ElementAtOrDefault(1) ?? firstType;
        object?[][] examples =
        [
            ["MSKU1234565", firstType, 2100m, baseCode, today.ToDateTime(TimeOnly.MinValue), null, null, "INV-2026-001", null,
                $"{ExampleMarker} - delete before importing"],
            ["KTG-2026-0031", secondType, 840m, null, null, null, null, "INV-2026-001", "Quantity",
                $"{ExampleMarker} - delete before importing"],
        ];

        for (var row = 0; row < examples.Length; row++)
        {
            for (var column = 0; column < examples[row].Length; column++)
            {
                SetCell(sheet.Cell(row + 2, column + 1), examples[row][column]);
            }

            sheet.Range(row + 2, 1, row + 2, headers.Length).Style.Font.FontColor = XLColor.FromArgb(0x6B, 0x72, 0x80);
            sheet.Range(row + 2, 1, row + 2, headers.Length).Style.Font.Italic = true;
        }

        // Formats on the whole columns, so what is typed under the examples reads the same way.
        sheet.Range(2, 3, ListRows, 3).Style.NumberFormat.Format = AmountFormat;
        sheet.Range(2, 5, ListRows, 5).Style.DateFormat.Format = DateFormat;
        sheet.Range(2, 6, ListRows, 6).Style.NumberFormat.Format = RateFormat;
        // Text, so an invoice number such as 000123 keeps its zeros.
        sheet.Range(2, 8, ListRows, 8).Style.NumberFormat.Format = "@";

        // Sheets in reading order: Charges (the first, the one that opens), Instructions, Lists.
        AddInstructions(workbook, baseCode);
        var lists = AddLists(workbook, activeTypes, activeCurrencies);
        AddDropDowns(sheet, lists, activeTypes.Count, activeCurrencies.Count);

        sheet.SheetView.FreezeRows(1);
        sheet.Columns().AdjustToContents();
        sheet.Column(1).Width = Math.Max(sheet.Column(1).Width, 18);
        sheet.Column(2).Width = Math.Max(sheet.Column(2).Width, 16);
        sheet.Column(7).Width = Math.Max(sheet.Column(7).Width, 22);
        sheet.Column(10).Width = 44;

        return ToBytes(workbook);
    }

    /// <summary>
    /// The Warning and Error rows, as the file had them, with Status and Message. A Valid row is not in it:
    /// the report is "what to look at", and a warning row IS imported, so it is listed but not to be fixed.
    /// </summary>
    public byte[] GenerateErrorReport(IReadOnlyList<ContainerChargeImportValidatedRow> rows)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.AddWorksheet(ContainerChargeImportParser.DataSheetName);

        string[] headers = ["Row", .. ContainerChargeImportParser.TemplateHeaders, "Status", "Message"];
        for (var index = 0; index < headers.Length; index++)
        {
            sheet.Cell(1, index + 1).Value = headers[index];
        }

        StyleHeader(sheet.Range(1, 1, 1, headers.Length));

        var problems = rows
            .Where(r => !string.Equals(r.Status, ContainerChargeImportStatus.Valid, StringComparison.Ordinal))
            .OrderBy(r => r.RowNumber)
            .ToList();

        var rowNumber = 2;
        foreach (var row in problems)
        {
            sheet.Cell(rowNumber, 1).Value = row.RowNumber;
            // WHAT WAS TYPED, not what it resolved to: on the row that failed because a code is unknown there
            // is nothing resolved, and a blank cell the import filled in (today, the type's method) stays blank.
            SetCell(sheet.Cell(rowNumber, 2), row.ContainerInput);
            SetCell(sheet.Cell(rowNumber, 3), row.ChargeTypeInput);
            SetCell(sheet.Cell(rowNumber, 4), (object?)row.Amount ?? row.RawAmount);
            SetCell(sheet.Cell(rowNumber, 5), row.CurrencyInput);
            SetCell(sheet.Cell(rowNumber, 6), row.ChargeDateDefaulted ? null
                : (object?)row.ChargeDate?.ToDateTime(TimeOnly.MinValue) ?? row.RawChargeDate);
            SetCell(sheet.Cell(rowNumber, 7), row.ExchangeRateLookedUp ? null : (object?)row.ExchangeRate ?? row.RawExchangeRate);
            SetCell(sheet.Cell(rowNumber, 8), row.ProviderInput);
            SetCell(sheet.Cell(rowNumber, 9), row.Reference);
            SetCell(sheet.Cell(rowNumber, 10), row.AllocationInput);
            SetCell(sheet.Cell(rowNumber, 11), row.Notes);
            sheet.Cell(rowNumber, 12).Value = row.Status;
            SetCell(sheet.Cell(rowNumber, 13), row.Message);

            var colour = row.Status switch
            {
                ContainerChargeImportStatus.Error => XLColor.FromArgb(0xC0, 0x39, 0x2B),
                ContainerChargeImportStatus.Warning => XLColor.FromArgb(0xD3, 0x7A, 0x06),
                _ => XLColor.FromArgb(0x6B, 0x72, 0x80),
            };

            // Only the status and the message carry the colour: the values on the left are what gets corrected.
            sheet.Range(rowNumber, 12, rowNumber, 13).Style.Font.FontColor = colour;
            sheet.Cell(rowNumber, 12).Style.Font.Bold = true;

            rowNumber++;
        }

        sheet.Column(4).Style.NumberFormat.Format = AmountFormat;
        sheet.Column(6).Style.DateFormat.Format = DateFormat;
        sheet.Column(7).Style.NumberFormat.Format = RateFormat;
        sheet.SheetView.FreezeRows(1);
        sheet.Columns().AdjustToContents();
        sheet.Column(13).Width = 80;
        sheet.Column(13).Style.Alignment.WrapText = true;

        return ToBytes(workbook);
    }

    /// <summary>The ranges of the Lists sheet the drop-downs point at.</summary>
    private sealed record ListRanges(IXLRange? ChargeCodes, IXLRange? CurrencyCodes, IXLRange Allocations);

    private static ListRanges AddLists(
        XLWorkbook workbook, IReadOnlyList<ChargeTypeLookupDto> types, IReadOnlyList<CurrencyLookup> currencies)
    {
        var sheet = workbook.AddWorksheet("Lists");

        // Charge types: A–D.
        sheet.Cell(1, 1).Value = "Charge types (active)";
        sheet.Cell(1, 1).Style.Font.Bold = true;
        string[] typeHeaders = ["Code", "Name", "Default allocation", "Enters landed cost"];
        for (var i = 0; i < typeHeaders.Length; i++)
        {
            sheet.Cell(2, i + 1).Value = typeHeaders[i];
        }

        StyleHeader(sheet.Range(2, 1, 2, typeHeaders.Length));
        var row = 3;
        foreach (var type in types)
        {
            sheet.Cell(row, 1).Value = type.ChargeCode;
            sheet.Cell(row, 2).Value = type.ChargeName;
            sheet.Cell(row, 3).Value = type.AllocationMethod;
            sheet.Cell(row, 4).Value = type.IncludeInLandedCost ? "Yes" : "No";
            row++;
        }

        if (types.Count == 0)
        {
            sheet.Cell(3, 1).Value = "No active charge type: add one in Purchase › Charge Types.";
        }

        // Currencies: F–H.
        sheet.Cell(1, 6).Value = "Currencies (active)";
        sheet.Cell(1, 6).Style.Font.Bold = true;
        string[] currencyHeaders = ["Code", "Name", "Base currency"];
        for (var i = 0; i < currencyHeaders.Length; i++)
        {
            sheet.Cell(2, i + 6).Value = currencyHeaders[i];
        }

        StyleHeader(sheet.Range(2, 6, 2, 8));
        row = 3;
        foreach (var currency in currencies)
        {
            sheet.Cell(row, 6).Value = currency.CurrencyCode;
            sheet.Cell(row, 7).Value = currency.CurrencyName;
            sheet.Cell(row, 8).Value = currency.IsBaseCurrency ? "Yes" : string.Empty;
            row++;
        }

        // Allocation methods: J–K.
        sheet.Cell(1, 10).Value = "Allocation methods";
        sheet.Cell(1, 10).Style.Font.Bold = true;
        sheet.Cell(2, 10).Value = "Method";
        sheet.Cell(2, 11).Value = "How the amount is divided over the container's items";
        StyleHeader(sheet.Range(2, 10, 2, 11));
        row = 3;
        foreach (var (method, meaning) in AllocationMethods)
        {
            sheet.Cell(row, 10).Value = method;
            sheet.Cell(row, 11).Value = meaning;
            row++;
        }

        sheet.SheetView.FreezeRows(2);
        sheet.Columns().AdjustToContents();
        sheet.Column(11).Width = 70;

        return new ListRanges(
            types.Count > 0 ? sheet.Range(3, 1, 2 + types.Count, 1) : null,
            currencies.Count > 0 ? sheet.Range(3, 6, 2 + currencies.Count, 6) : null,
            sheet.Range(3, 10, 2 + AllocationMethods.Length, 10));
    }

    /// <summary>
    /// Drop-downs on Charge Type, Currency and Allocation. The first two do not refuse what is typed: a charge
    /// type's NAME is as good as its code, and the import judges it. Allocation offers the four methods only.
    /// </summary>
    private static void AddDropDowns(IXLWorksheet sheet, ListRanges lists, int typeCount, int currencyCount)
    {
        if (lists.ChargeCodes is not null && typeCount > 0)
        {
            var types = sheet.Range(2, 2, ListRows, 2).CreateDataValidation();
            types.List(lists.ChargeCodes, true);
            types.IgnoreBlanks = true;
            types.ShowErrorMessage = false;
        }

        if (lists.CurrencyCodes is not null && currencyCount > 0)
        {
            var currencies = sheet.Range(2, 4, ListRows, 4).CreateDataValidation();
            currencies.List(lists.CurrencyCodes, true);
            currencies.IgnoreBlanks = true;
            currencies.ShowErrorMessage = false;
        }

        var allocation = sheet.Range(2, 9, ListRows, 9).CreateDataValidation();
        allocation.List(lists.Allocations, true);
        allocation.IgnoreBlanks = true;
        allocation.ShowErrorMessage = true;
        allocation.ErrorTitle = "Allocation";
        allocation.ErrorMessage = "Value, Quantity, Weight or Volume - or blank for the charge type's default.";
    }

    /// <summary>Column, whether it is required, and what happens — the invoice import's Instructions sheet, for charges.</summary>
    private static void AddInstructions(XLWorkbook workbook, string baseCode)
    {
        var sheet = workbook.AddWorksheet("Instructions");

        sheet.Cell(1, 1).Value = "Column";
        sheet.Cell(1, 2).Value = "Required";
        sheet.Cell(1, 3).Value = "What happens";
        StyleHeader(sheet.Range(1, 1, 1, 3));

        (string Column, string Required, string Behaviour)[] instructions =
        [
            (ContainerChargeImportParser.ColumnContainer, "Required",
                "The container number (MSKU1234565) or the app reference (KTG-2026-0031). Capitals, spaces, dashes, dots and slashes are ignored. "
                + "A closed or cancelled container is refused: reopen a closed container to add a late charge. "
                + "A number found on two containers not yet offloaded is refused: type the reference instead. "
                + "Otherwise a number on several containers goes on the one not yet offloaded, else the latest offloaded one, "
                + "and the row warns and names the others."),
            (ContainerChargeImportParser.ColumnChargeType, "Required",
                "The code or the name of an active charge type (sheet Lists). It decides whether the charge enters the landed cost, and its default allocation."),
            (ContainerChargeImportParser.ColumnAmount, "Required",
                "The amount for THIS container, in the row's currency, greater than zero. It is rounded to the cent. "
                + "Typed as text, the decimals take a point and commas only group thousands (2,100.50): 2100,50 is refused, not read as 210050."),
            (ContainerChargeImportParser.ColumnCurrency, "Optional",
                $"A currency code (sheet Lists). Blank is the base currency ({baseCode})."),
            (ContainerChargeImportParser.ColumnChargeDate, "Optional",
                "The date of the charge, dd/MM/yyyy (or a date cell). Blank is today."),
            (ContainerChargeImportParser.ColumnExchangeRate, "Optional",
                $"Units of the currency per 1 {baseCode}. Blank takes the official rate of the charge date from Master Data › Exchange Rates, "
                + "like the charge dialog; a row without a rate for that date is refused. Ignored for the base currency (always 1). "
                + "Decimals with a point, like the Amount."),
            (ContainerChargeImportParser.ColumnProvider, "Optional",
                "The code or the name of the supplier who bills the charge (Master Data › Parties). Blank leaves the charge without a provider."),
            (ContainerChargeImportParser.ColumnProviderInvoiceNo, "Optional",
                "The provider's invoice number, kept as the charge's reference (100 characters at most)."),
            (ContainerChargeImportParser.ColumnAllocation, "Optional",
                "How the amount is divided over the container's items: Value, Quantity, Weight or Volume (sheet Lists). Blank is the charge type's default. "
                + "Manual is not possible in an import: change the allocation on the charge afterwards."),
            (ContainerChargeImportParser.ColumnNotes, "Optional",
                "Free text kept on the charge (300 characters at most)."),
        ];

        var rowNumber = 2;
        foreach (var (column, required, behaviour) in instructions)
        {
            sheet.Cell(rowNumber, 1).Value = column;
            sheet.Cell(rowNumber, 2).Value = required;
            sheet.Cell(rowNumber, 3).Value = behaviour;
            rowNumber++;
        }

        string[] notes =
        [
            "ONE ROW = ONE CHARGE ON ONE CONTAINER: the whole amount goes on that container and is divided over its items by the allocation.",
            "Rows with the same Charge Type, Provider, Provider Invoice No., Charge Date, Currency, Exchange Rate and Notes become one charge group, "
                + "so the provider's invoice can be attached once. Rows without a Provider Invoice No. are charges on their own.",
            "The charges are created as drafts. Tick \"Post the charges\" in the import to post them at once (it needs the permission to post container charges); "
                + "a row that cannot be posted stays a draft and the import says why.",
            "Each row is created on its own: a row refused at the import is reported with its reason, and the others are still created.",
            "Two identical rows are imported twice (the preview warns). A row equal to a charge the container already has is warned about too.",
            $"Delete the example rows (their Notes start with \"{ExampleMarker}\") before importing: the import refuses them. "
                + $"Blank rows are ignored. At most {ContainerChargeImportParser.MaxDataRows} rows per file.",
        ];

        rowNumber++;
        foreach (var note in notes)
        {
            sheet.Cell(rowNumber, 1).Value = note;
            var merged = sheet.Range(rowNumber, 1, rowNumber, 3).Merge();
            merged.Style.Font.Italic = true;
            merged.Style.Alignment.WrapText = true;
            sheet.Row(rowNumber).Height = 30;
            rowNumber++;
        }

        sheet.Column(1).Width = 22;
        sheet.Column(2).Width = 12;
        sheet.Column(3).Width = 110;
        sheet.Column(3).Style.Alignment.WrapText = true;
        sheet.SheetView.FreezeRows(1);
    }

    private static void StyleHeader(IXLRange header)
    {
        header.Style.Font.Bold = true;
        header.Style.Fill.BackgroundColor = HeaderFill;
        header.Style.Border.BottomBorder = XLBorderStyleValues.Thin;
    }

    /// <summary>A value with its own type, so a number stays a number and the report can be uploaded again.</summary>
    private static void SetCell(IXLCell cell, object? value)
    {
        switch (value)
        {
            case null:
                return;
            case string text:
                cell.Value = text;
                return;
            case int number:
                cell.Value = number;
                return;
            case decimal number:
                cell.Value = number;
                return;
            case double number:
                cell.Value = number;
                return;
            case DateTime date:
                cell.Value = date;
                cell.Style.DateFormat.Format = DateFormat;
                return;
            default:
                cell.Value = value.ToString();
                return;
        }
    }

    private static byte[] ToBytes(XLWorkbook workbook)
    {
        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }
}
