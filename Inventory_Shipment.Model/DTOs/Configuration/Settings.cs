namespace Inventory_Shipment.Model.DTOs.Configuration;

/// <summary>
/// One global setting as the Settings page shows it: what the setting IS (key, label, type, default,
/// limits) and what it is set to NOW. Definitions belong to the application; only the value is edited.
/// </summary>
public sealed class SettingDto
{
    /// <summary>"Area.Name", e.g. Sales.AllowOutOfStock. The same key reads the setting from code.</summary>
    public string SettingKey { get; init; } = string.Empty;

    /// <summary>The heading it sits under on the page.</summary>
    public string GroupName { get; init; } = string.Empty;

    public string Label { get; init; } = string.Empty;
    public string? Description { get; init; }

    /// <summary>bool, int, decimal or text. Values travel as text; the type says how to read and edit them.</summary>
    public string ValueType { get; init; } = "text";

    public string DefaultValue { get; init; } = string.Empty;
    public decimal? MinValue { get; init; }
    public decimal? MaxValue { get; init; }

    /// <summary>Readable by any signed-in user (through the lookup), not only by those who manage settings.</summary>
    public bool IsPublic { get; init; }

    public int SortOrder { get; init; }

    /// <summary>The effective value: the administrator's choice, or the default when none was made.</summary>
    public string Value { get; init; } = string.Empty;

    /// <summary>True while no choice has been made, so the default applies.</summary>
    public bool IsDefault { get; init; }

    public DateTime? UpdatedAtUtc { get; init; }
    public string? UpdatedByName { get; init; }
}

/// <summary>The part of a public setting any screen may read: its key, its type and its value.</summary>
public sealed class SettingLookupDto
{
    public string SettingKey { get; init; } = string.Empty;
    public string ValueType { get; init; } = "text";
    public string Value { get; init; } = string.Empty;
}

public sealed class SaveSettingRequest
{
    /// <summary>The new value as text ("true" / "false", "30", "2.5", or free text). Validated against the setting's type and limits.</summary>
    public string? Value { get; init; }
}
