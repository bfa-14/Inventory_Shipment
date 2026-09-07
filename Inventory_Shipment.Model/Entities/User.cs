namespace Inventory_Shipment.Model.Entities;

/// <summary>
/// Application user (table security.Users). Passwords are never stored - only an Argon2id hash.
/// Roles are not part of this entity: a user holds zero or more roles through security.UserRoles
/// (see <see cref="Security.UserAccess"/>).
/// </summary>
public class User
{
    public int Id { get; set; }
    public string Username { get; set; } = string.Empty;
    public string Email { get; set; } = string.Empty;
    public string FullName { get; set; } = string.Empty;
    public string PasswordHash { get; set; } = string.Empty;
    public bool IsActive { get; set; } = true;
    public int FailedLoginAttempts { get; set; }
    public DateTime? LockoutEndUtc { get; set; }
    public DateTime? LastLoginAtUtc { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public DateTime? UpdatedAtUtc { get; set; }

    public bool IsLockedOut(DateTime utcNow) => LockoutEndUtc.HasValue && LockoutEndUtc.Value > utcNow;
}

/// <summary>
/// The smallest projection of security.Users - what a "pick a user" dropdown needs. Deliberately
/// carries no password hash, e-mail, roles or sign-in history, because any signed-in user may read it.
/// </summary>
public sealed class UserLookup
{
    public int Id { get; set; }
    public string Username { get; set; } = string.Empty;
    public string FullName { get; set; } = string.Empty;
    public bool IsActive { get; set; }
}
