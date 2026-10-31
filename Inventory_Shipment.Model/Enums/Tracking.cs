using System.Text.Json.Serialization;

namespace Inventory_Shipment.Model.Enums;

/// <summary>
/// (93) HOW AN ITEM IS TRACKED (Item Definition › Tracking; inventory.Items.TrackingMode TINYINT): no numbers, a batch
/// number per group of pieces, or a serial number per piece (a TVS chassis no.). Exchanged as a string in JSON
/// ("None", "Batch", "Serial"). Asked on transfer dispatches only (script 93, B1): the flags are generic, the modules
/// that ask for them say so.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<TrackingMode>))]
public enum TrackingMode : byte
{
    None = 0,
    Batch = 1,
    Serial = 2,
}

/// <summary>
/// (93) WHAT A DISPATCH ASKS FOR A LINE, derived from the item and never stored on it: Serial (one row per piece), Batch
/// (batch no., expiry, pcs) or Expiry (an item of no tracking that requires an expiry date: expiry, pcs). The procedures
/// write it as K(i) = 2 / 1 / 3 / NULL; a dispatch line keeps the one it left with (TransferPostingLines.TrackingKind),
/// and its receipt follows it whatever the item says now (B3). Exchanged as a string in JSON; null = no tracking.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<TrackingKind>))]
public enum TrackingKind : byte
{
    Batch = 1,
    Serial = 2,
    Expiry = 3,
}

/// <summary>The two tracking rules the API needs in C#: the names a request may carry, and K(i).</summary>
public static class Tracking
{
    /// <summary>
    /// K(i), as the procedures write it inline: Serial numbers → Serial, Batch numbers → Batch, otherwise Expiry when the
    /// item requires an expiry date, else none. Serial and batch items that require an expiry ask it on their rows.
    /// </summary>
    public static TrackingKind? KindOf(TrackingMode mode, bool requiresExpiry) => mode switch
    {
        TrackingMode.Serial => TrackingKind.Serial,
        TrackingMode.Batch => TrackingKind.Batch,
        _ => requiresExpiry ? TrackingKind.Expiry : null,
    };

    /// <summary>"None" | "Batch" | "Serial" (case and surrounding spaces ignored); a number or any other word is refused.</summary>
    public static bool TryParseMode(string? value, out TrackingMode mode)
    {
        mode = TrackingMode.None;
        var text = value?.Trim();
        if (string.IsNullOrEmpty(text) || !char.IsLetter(text[0]))
        {
            return false;
        }

        return Enum.TryParse(text, ignoreCase: true, out mode) && Enum.IsDefined(mode);
    }
}
