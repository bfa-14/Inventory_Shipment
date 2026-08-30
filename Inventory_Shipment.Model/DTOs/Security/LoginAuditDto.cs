using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Security;

/// <summary>One sign-in attempt from security.LoginAudit.</summary>
public sealed class LoginAuditDto
{
    public long Id { get; init; }
    public string Username { get; init; } = string.Empty;
    public int? UserId { get; init; }
    public bool Succeeded { get; init; }

    /// <summary>UnknownUser, WrongPassword, WrongPassword_LockedOut, LockedOut or Inactive; null on success.</summary>
    public string? FailureReason { get; init; }

    public string? IpAddress { get; init; }
    public string? UserAgent { get; init; }
    public DateTime AttemptedAtUtc { get; init; }
}

/// <summary>Filters for the login-audit list (bound from the query string).</summary>
public sealed class LoginAuditQuery
{
    /// <summary>Exact username match (case-insensitive per the database collation).</summary>
    public string? Username { get; init; }

    public bool OnlyFailed { get; init; }

    [Range(1, 1000)]
    public int Take { get; init; } = 200;
}
