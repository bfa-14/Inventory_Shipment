using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.Options;

/// <summary>Bound from the "Jwt" configuration section.</summary>
public sealed class JwtOptions
{
    public const string SectionName = "Jwt";

    [Required]
    public string Issuer { get; set; } = "InventoryShipment.API";

    [Required]
    public string Audience { get; set; } = "InventoryShipment.Client";

    /// <summary>
    /// HMAC-SHA256 signing key. Never commit a production key: set it with
    /// <c>dotnet user-secrets set "Jwt:SecretKey" "..."</c> or the environment variable <c>Jwt__SecretKey</c>.
    /// </summary>
    [Required(ErrorMessage = "Jwt:SecretKey is not configured. Set it with user-secrets or the Jwt__SecretKey environment variable.")]
    [MinLength(32, ErrorMessage = "Jwt:SecretKey must be at least 32 characters (256 bits).")]
    public string SecretKey { get; set; } = string.Empty;

    [Range(1, 1440)]
    public int AccessTokenMinutes { get; set; } = 15;

    [Range(1, 365)]
    public int RefreshTokenDays { get; set; } = 7;
}
