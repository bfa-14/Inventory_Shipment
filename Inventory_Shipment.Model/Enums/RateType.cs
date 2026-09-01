using System.Text.Json.Serialization;

namespace Inventory_Shipment.Model.Enums;

/// <summary>
/// The kind of exchange rate a row records. Stored as TINYINT in masterdata.ExchangeRates and
/// exchanged as a string in JSON ("Official", "NonOfficial", "Market"). The converter is declared on
/// the type itself so the OpenAPI schema advertises the string form too, not only the serializer.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<RateType>))]
public enum RateType : byte
{
    /// <summary>The rate published by the central bank.</summary>
    Official = 1,

    /// <summary>The parallel / street rate.</summary>
    NonOfficial = 2,

    /// <summary>The rate the business actually trades at.</summary>
    Market = 3
}
