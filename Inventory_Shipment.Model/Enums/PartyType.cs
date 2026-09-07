using System.Text.Json.Serialization;

namespace Inventory_Shipment.Model.Enums;

/// <summary>
/// A role a party can play. Parties are one centralized master with four independent flags, so a
/// party may be several types at once; this enum names a single role when filtering a list or a
/// dropdown ("the suppliers"). Exchanged as a string in JSON and passed to the procedures by name.
/// The converter is declared on the type itself so the OpenAPI schema advertises the string form too.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<PartyType>))]
public enum PartyType
{
    Supplier = 1,
    Client = 2,
    Salesman = 3,
    Employee = 4
}
