using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;

namespace Inventory_Shipment.API.Extensions;

/// <summary>
/// EVERY *Utc TIME LEAVES THE API AS UTC: "2026-10-01T20:26:00Z", so a browser shows it in its own time zone.
///
/// The values are UTC in the database (SYSUTCDATETIME) but Dapper reads a datetime2 as a DateTime of kind
/// Unspecified, which System.Text.Json writes without a zone - and a browser then reads "20:26" as LOCAL time, hours
/// off. The rule is the code base's own naming convention: a DateTime property whose name ends in "Utc" holds an
/// instant (191 of them across the DTOs, e.g. CreatedAtUtc, LastLoginAtUtc, ExpiresAtUtc, LinksValidUntilUtc); every
/// other DateTime is a calendar date (DocumentDate, OrderDate, Eta, ExpiryDate...) and keeps no zone. A JSON modifier
/// rather than a Dapper type handler, because a handler would see the DATE columns too: the column type decides
/// nothing there, the property's meaning does.
///
/// Read too: a *Utc value sent without a zone is taken as UTC, one with an offset is converted to UTC.
/// </summary>
public static class UtcDateTimeJson
{
    private const string Suffix = "Utc";

    /// <summary>The <see cref="DefaultJsonTypeInfoResolver"/> modifier: the *Utc DateTime properties get the UTC converters.</summary>
    public static void MarkUtcProperties(JsonTypeInfo typeInfo)
    {
        if (typeInfo.Kind != JsonTypeInfoKind.Object)
        {
            return;
        }

        foreach (var property in typeInfo.Properties)
        {
            if (property.CustomConverter is not null || !property.Name.EndsWith(Suffix, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (property.PropertyType == typeof(DateTime))
            {
                property.CustomConverter = UtcDateTimeConverter.Instance;
            }
            else if (property.PropertyType == typeof(DateTime?))
            {
                property.CustomConverter = NullableUtcDateTimeConverter.Instance;
            }
        }
    }

    internal static DateTime AsUtc(DateTime value) => value.Kind switch
    {
        DateTimeKind.Utc => value,
        DateTimeKind.Local => value.ToUniversalTime(),
        _ => DateTime.SpecifyKind(value, DateTimeKind.Utc),
    };

    private sealed class UtcDateTimeConverter : JsonConverter<DateTime>
    {
        public static readonly UtcDateTimeConverter Instance = new();

        public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
            => AsUtc(reader.GetDateTime());

        public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options)
            => writer.WriteStringValue(AsUtc(value));
    }

    private sealed class NullableUtcDateTimeConverter : JsonConverter<DateTime?>
    {
        public static readonly NullableUtcDateTimeConverter Instance = new();

        public override bool HandleNull => true;

        public override DateTime? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
            => reader.TokenType == JsonTokenType.Null ? null : AsUtc(reader.GetDateTime());

        public override void Write(Utf8JsonWriter writer, DateTime? value, JsonSerializerOptions options)
        {
            if (value is { } instant)
            {
                writer.WriteStringValue(AsUtc(instant));
            }
            else
            {
                writer.WriteNullValue();
            }
        }
    }
}
