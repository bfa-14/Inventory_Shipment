using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Body of both POST (create) and PUT (update) on a currency.</summary>
public sealed class SaveCurrencyRequest
{
    /// <summary>ISO 4217 code - exactly 3 letters. The service normalizes it to upper case.</summary>
    [Required]
    [StringLength(3, MinimumLength = 3)]
    [RegularExpression("^[A-Za-z]{3}$", ErrorMessage = "Currency Code must be exactly 3 letters (ISO 4217, e.g. USD).")]
    public string CurrencyCode { get; init; } = string.Empty;

    [Required]
    [StringLength(100, MinimumLength = 1)]
    public string CurrencyName { get; init; } = string.Empty;

    [StringLength(10)]
    public string? Symbol { get; init; }

    /// <summary>Digits after the decimal separator (0-6); 0 for currencies without cents.</summary>
    [Range(0, 6)]
    public byte DecimalPlaces { get; init; } = 2;

    /// <summary>Amounts are stored and reported in the base currency. Only one active currency may hold it.</summary>
    public bool IsBaseCurrency { get; init; }

    public bool IsActive { get; init; } = true;

    /// <summary>
    /// Set to true to confirm taking the Base Currency flag away from the currency that holds it.
    /// Without it the request fails with BASE_CURRENCY_EXISTS so the user can be asked first.
    /// </summary>
    public bool ReplaceBaseCurrency { get; init; }

    /// <summary>Base64 ROWVERSION read with the currency (update only). Null skips the concurrency check.</summary>
    public string? RowVersion { get; init; }
}
