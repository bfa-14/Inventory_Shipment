using System.Globalization;
using System.Net;
using System.Text;
using Inventory_Shipment.Model.DTOs.Purchase;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// The HTML of the purchase emails. MAIL CLIENTS, NOT BROWSERS: tables for the layout, inline styles only
/// (Outlook and Gmail drop &lt;style&gt; blocks and classes), no image, no script, buttons drawn as a
/// table cell with a background colour around a styled link - the one shape every client renders.
/// Every value from the database is HTML-encoded here.
/// </summary>
internal static class PurchaseEmailHtml
{
    internal const string CompanyName = "Katanga TVS Motor Company";
    internal const string Green = "#2f9e44";
    internal const string Red = "#e03131";
    internal const string Blue = "#1c7ed6";

    private const string Font = "font-family:'Segoe UI',Arial,Helvetica,sans-serif;";
    private const int ShownLines = 10;

    private static readonly CultureInfo Numbers = CultureInfo.InvariantCulture;

    internal static string E(string? text) => WebUtility.HtmlEncode(text ?? string.Empty);

    internal static string Date(DateTime value) => value.ToString("d MMM yyyy", Numbers);

    internal static string Stamp(DateTime utc) => utc.ToString("d MMM yyyy HH:mm 'UTC'", Numbers);

    internal static string Money(decimal value, int decimals = 2) => value.ToString("N" + Math.Clamp(decimals, 0, 4), Numbers);

    /// <summary>The page around the content: the company line on top, a white card, a footer.</summary>
    internal static string Page(string title, string content)
        => $"""
           <!DOCTYPE html>
           <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>{E(title)}</title></head>
           <body style="margin:0;padding:0;background:#f3f4f6;">
           <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f3f4f6;">
           <tr><td align="center" style="padding:24px 12px;">
           <table role="presentation" width="640" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:640px;background:#ffffff;border:1px solid #e5e7eb;border-radius:8px;">
           <tr><td style="padding:18px 24px;border-bottom:3px solid #013596;{Font}font-size:13px;font-weight:600;color:#013596;letter-spacing:0.3px;">{E(CompanyName)}</td></tr>
           <tr><td style="padding:24px;{Font}font-size:14px;line-height:1.5;color:#1f2937;">
           {content}
           </td></tr>
           <tr><td style="padding:14px 24px;border-top:1px solid #e5e7eb;{Font}font-size:12px;line-height:1.4;color:#9ca3af;">Sent by the Inventory &amp; Shipment application of {E(CompanyName)}.</td></tr>
           </table>
           </td></tr></table>
           </body></html>
           """;

    internal static string Heading(string text)
        => $"""<h1 style="margin:0 0 16px 0;{Font}font-size:20px;line-height:1.3;color:#111827;">{E(text)}</h1>""";

    internal static string Paragraph(string text, string color = "#1f2937")
        => $"""<p style="margin:0 0 14px 0;{Font}font-size:14px;line-height:1.5;color:{color};">{E(text)}</p>""";

    /// <summary>A paragraph whose text is already HTML (a sentence with a link in it).</summary>
    internal static string ParagraphHtml(string html, string color = "#1f2937")
        => $"""<p style="margin:0 0 14px 0;{Font}font-size:14px;line-height:1.5;color:{color};">{html}</p>""";

    internal static string Link(string url, string? text = null)
        => $"""<a href="{E(url)}" target="_blank" style="color:#1c7ed6;text-decoration:underline;word-break:break-all;">{E(text ?? url)}</a>""";

    /// <summary>"Bulletproof" buttons: each one a cell with the colour as bgcolor and a styled link, side by side.</summary>
    internal static string Buttons(params (string Text, string Url, string Color)[] buttons)
    {
        var cells = new StringBuilder();
        foreach (var (text, url, color) in buttons)
        {
            cells.Append($"""
                <td style="padding:0 10px 10px 0;">
                <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
                <td align="center" bgcolor="{color}" style="border-radius:6px;background:{color};">
                <a href="{E(url)}" target="_blank" style="display:inline-block;padding:12px 22px;{Font}font-size:15px;font-weight:600;line-height:1.2;color:#ffffff;text-decoration:none;border-radius:6px;">{E(text)}</a>
                </td></tr></table>
                </td>
                """);
        }

        return $"""<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:6px 0 10px 0;"><tr>{cells}</tr></table>""";
    }

    /// <summary>The summary every purchase email carries: supplier, date, currency, total, lines, requested by, notes.</summary>
    internal static string Summary(PurchaseDocumentDto order, string? requestedBy)
    {
        var rows = new List<(string Label, string Value)>
        {
            ("Supplier", order.SupplierName),
            ("Order", order.DocumentNumber ?? $"draft #{order.Id}"),
            ("Order date", Date(order.DocumentDate)),
            ("Currency", order.CurrencyCode),
            ("Total", $"{Money(order.TotalAmount, order.DecimalPlaces)} {order.CurrencyCode}"),
            ("Lines", order.Lines.Count.ToString(Numbers)),
        };
        if (!string.IsNullOrWhiteSpace(requestedBy))
        {
            rows.Add(("Requested by", requestedBy));
        }

        if (!string.IsNullOrWhiteSpace(order.Notes))
        {
            rows.Add(("Notes", order.Notes));
        }

        var html = new StringBuilder("""<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:6px 0 18px 0;border-collapse:collapse;">""");
        foreach (var (label, value) in rows)
        {
            html.Append($"""
                <tr><td style="padding:6px 12px 6px 0;width:130px;vertical-align:top;border-bottom:1px solid #f1f3f5;{Font}font-size:13px;color:#6b7280;">{E(label)}</td>
                <td style="padding:6px 0;vertical-align:top;border-bottom:1px solid #f1f3f5;{Font}font-size:14px;color:#111827;{(label == "Total" ? "font-weight:700;" : string.Empty)}">{E(value)}</td></tr>
                """);
        }

        return html.Append("</table>").ToString();
    }

    /// <summary>The first 10 lines (code, item, quantity, unit price, line total) and "and N more lines".</summary>
    internal static string Lines(PurchaseDocumentDto order)
    {
        const string th = "padding:8px 6px;border-bottom:2px solid #e5e7eb;font-size:12px;font-weight:600;color:#6b7280;text-transform:uppercase;";
        const string td = "padding:8px 6px;border-bottom:1px solid #f1f3f5;font-size:13px;color:#1f2937;vertical-align:top;";
        var html = new StringBuilder($"""
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:0 0 8px 0;border-collapse:collapse;{Font}">
            <tr><td style="{th}text-align:left;">Code</td><td style="{th}text-align:left;">Item</td><td style="{th}text-align:right;">Qty</td><td style="{th}text-align:right;">Unit price</td><td style="{th}text-align:right;">Line total</td></tr>
            """);
        foreach (var line in order.Lines.Take(ShownLines))
        {
            html.Append($"""
                <tr><td style="{td}white-space:nowrap;">{E(line.ItemCode)}</td><td style="{td}">{E(line.ItemName)}</td>
                <td style="{td}text-align:right;white-space:nowrap;">{line.Quantity.ToString("N0", Numbers)} {E(line.UnitTypeName)}</td>
                <td style="{td}text-align:right;white-space:nowrap;">{Money(line.UnitPrice, Math.Max((int)order.DecimalPlaces, 2))}</td>
                <td style="{td}text-align:right;white-space:nowrap;">{Money(line.LineTotal, order.DecimalPlaces)}</td></tr>
                """);
        }

        html.Append("</table>");
        var more = order.Lines.Count - ShownLines;
        if (more > 0)
        {
            html.Append(Paragraph($"and {more} more line{(more == 1 ? string.Empty : "s")}", "#6b7280"));
        }

        return html.ToString();
    }
}
