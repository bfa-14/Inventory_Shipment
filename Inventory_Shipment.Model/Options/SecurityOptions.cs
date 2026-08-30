using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.Options;

/// <summary>Bound from the "Security" configuration section.</summary>
public sealed class SecurityOptions
{
    public const string SectionName = "Security";

    /// <summary>Failed attempts before the account is temporarily locked.</summary>
    [Range(1, 100)]
    public int MaxFailedLoginAttempts { get; set; } = 5;

    [Range(1, 1440)]
    public int LockoutMinutes { get; set; } = 15;

    public PasswordPolicyOptions PasswordPolicy { get; set; } = new();

    public Argon2Options Argon2 { get; set; } = new();

    public RateLimitOptions LoginRateLimit { get; set; } = new();
}

public sealed class PasswordPolicyOptions
{
    [Range(6, 128)]
    public int MinLength { get; set; } = 8;
    public bool RequireUppercase { get; set; } = true;
    public bool RequireLowercase { get; set; } = true;
    public bool RequireDigit { get; set; } = true;
    public bool RequireNonAlphanumeric { get; set; } = true;
}

/// <summary>
/// Argon2id parameters. Defaults follow RFC 9106's second recommended profile (64 MiB, 3 passes, 4 lanes).
/// Existing hashes are transparently re-hashed on next successful login when these change.
/// </summary>
public sealed class Argon2Options
{
    [Range(8192, 1_048_576)]
    public int MemoryKb { get; set; } = 65_536;

    [Range(1, 20)]
    public int Iterations { get; set; } = 3;

    [Range(1, 16)]
    public int Parallelism { get; set; } = 4;
}

/// <summary>Per-IP limit applied to the login and refresh endpoints.</summary>
public sealed class RateLimitOptions
{
    [Range(1, 10_000)]
    public int PermitLimit { get; set; } = 10;

    [Range(1, 3600)]
    public int WindowSeconds { get; set; } = 60;
}
