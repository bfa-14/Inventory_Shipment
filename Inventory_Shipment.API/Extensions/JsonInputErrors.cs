using System.Globalization;
using System.Text.RegularExpressions;

namespace Inventory_Shipment.API.Extensions;

/// <summary>
/// Turns what System.Text.Json says about a request body it could not read into a sentence a page
/// can show as it is: the path <c>$.lines[0].expiryDate</c> and "could not be converted to
/// System.Nullable`1[System.DateOnly]" become "Line 1: Expiry Date is not a valid date."
///
/// WHY: the formatter's own text names a CLR type and a byte offset, the pages show the API's
/// detail verbatim, and the binder adds "The request field is required." on top - so one wrong
/// value in one cell reached the user as two lines of exception text naming neither the line nor
/// the field.
///
/// NEVER THE VALUE: the sentence names the place and the kind of value expected, not what was sent,
/// so it is safe to log (a password field sent as a number says "is not valid", never the text).
/// </summary>
public static partial class JsonInputErrors
{
    /// <summary>True for a model-state key the JSON input formatter wrote: a JSON path ("$", "$.x", "$[0]").</summary>
    public static bool IsJsonPath(string key)
        => key == "$" || key.StartsWith("$.", StringComparison.Ordinal) || key.StartsWith("$[", StringComparison.Ordinal);

    /// <summary>A request path fit for the log: an approval token in it (64 hex characters) becomes "{token}".</summary>
    public static string SafePath(string? path) => path is null ? string.Empty : TokenSegment().Replace(path, "{token}");

    /// <summary>"Line 1: Expiry Date is not a valid date." from the path and the formatter's message.</summary>
    public static string Describe(string path, string message)
        => $"{Where(path)} {What(message)}.";

    /// <summary>
    /// "Line 1: Expiry Date", "Charge 2, Manual Allocation 1: Amount", "Warehouse", "The request".
    /// Every indexed segment becomes "Name n" (index + 1, singular); the last property is the field.
    /// </summary>
    private static string Where(string path)
    {
        var segments = path.TrimStart('$').Split('.', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length == 0)
        {
            return "The request";
        }

        var places = new List<string>();
        string? field = null;
        for (var i = 0; i < segments.Length; i++)
        {
            var match = IndexedSegment().Match(segments[i]);
            var name = match.Groups["name"].Value;
            var isLast = i == segments.Length - 1;

            if (match.Groups["index"].Success)
            {
                var index = int.Parse(match.Groups["index"].Value, CultureInfo.InvariantCulture) + 1;
                places.Add($"{Singular(Words(name))} {index}");
            }
            else if (isLast)
            {
                field = Words(name);
            }
        }

        var place = string.Join(", ", places);
        return (place.Length, field) switch
        {
            (0, null) => "The request",
            (0, _) => field!,
            (_, null) => place,
            _ => $"{place}: {field}",
        };
    }

    /// <summary>The kind of value the property expects, from the type the formatter names.</summary>
    private static string What(string message)
    {
        // RespectNullableAnnotations: "The property or field 'lines' on type '...' doesn't allow setting null values."
        if (message.Contains("null values", StringComparison.OrdinalIgnoreCase))
        {
            return "is required";
        }

        var converted = ConvertedTo().Match(message);
        if (!converted.Success)
        {
            return "is not valid";      // malformed JSON at that place: a stray character, a missing quote
        }

        var type = converted.Groups["type"].Value;
        var nullable = NullableOf().Match(type);
        if (nullable.Success)
        {
            type = nullable.Groups["inner"].Value;
        }

        return type switch
        {
            "System.Byte" or "System.SByte" or "System.Int16" or "System.UInt16" or "System.Int32"
                or "System.UInt32" or "System.Int64" or "System.UInt64" => "is not a valid whole number",
            "System.Decimal" or "System.Double" or "System.Single" => "is not a valid number",
            "System.DateOnly" or "System.DateTime" or "System.DateTimeOffset" => "is not a valid date",
            "System.TimeOnly" or "System.TimeSpan" => "is not a valid time",
            "System.Boolean" => "must be true or false",
            "System.String" => "must be text",
            _ when type.EndsWith("[]", StringComparison.Ordinal) || type.Contains("List`1", StringComparison.Ordinal)
                                                                  || type.Contains("Enumerable`1", StringComparison.Ordinal) => "must be a list",
            _ => "is not a valid value",
        };
    }

    /// <summary>"expiryDate" -> "Expiry Date"; "warehouseId" -> "Warehouse" (an id is the thing it points at).</summary>
    private static string Words(string name)
    {
        var words = WordBoundary().Split(name)
            .Where(w => w.Length > 0)
            .Select(w => char.ToUpperInvariant(w[0]) + w[1..])
            .ToList();

        if (words.Count > 1 && words[^1] == "Id")
        {
            words.RemoveAt(words.Count - 1);
        }

        return words.Count == 0 ? name : string.Join(' ', words);
    }

    /// <summary>"Lines" -> "Line", "Manual Allocations" -> "Manual Allocation", "Entries" -> "Entry".</summary>
    private static string Singular(string words)
    {
        if (words.EndsWith("ies", StringComparison.Ordinal))
        {
            return words[..^3] + "y";
        }

        return words.EndsWith('s') && !words.EndsWith("ss", StringComparison.Ordinal) ? words[..^1] : words;
    }

    [GeneratedRegex(@"^(?<name>[^\[]*)(\[(?<index>\d+)\])?")]
    private static partial Regex IndexedSegment();

    [GeneratedRegex(@"could not be converted to (?<type>.+?)\. Path:")]
    private static partial Regex ConvertedTo();

    [GeneratedRegex(@"^System\.Nullable`1\[(?<inner>.+)\]$")]
    private static partial Regex NullableOf();

    [GeneratedRegex(@"(?<=[a-z0-9])(?=[A-Z])")]
    private static partial Regex WordBoundary();

    [GeneratedRegex("[0-9A-Fa-f]{64}")]
    private static partial Regex TokenSegment();
}
