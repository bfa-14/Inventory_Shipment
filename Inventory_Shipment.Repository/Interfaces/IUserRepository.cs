using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Model.Security;

namespace Inventory_Shipment.Repository.Interfaces;

public interface IUserRepository
{
    Task<User?> GetByIdAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Finds a user by username or e-mail (case-insensitive, per the database collation).</summary>
    Task<User?> GetByUsernameOrEmailAsync(string usernameOrEmail, CancellationToken cancellationToken = default);

    Task<bool> UsernameExistsAsync(string username, CancellationToken cancellationToken = default);

    Task<bool> EmailExistsAsync(string email, CancellationToken cancellationToken = default);

    /// <summary>True when another user (not <paramref name="excludeUserId"/>) already uses that e-mail.</summary>
    Task<bool> EmailExistsForOtherUserAsync(string email, int excludeUserId, CancellationToken cancellationToken = default);

    Task<int> CountAsync(CancellationToken cancellationToken = default);

    Task<IReadOnlyList<User>> GetAllAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// Users for a "pick a user" dropdown, matched on username, full name or e-mail. Active users
    /// first, then by full name. <paramref name="includeId"/> keeps one extra user in the list even
    /// when it is inactive, so an edit form can still show the user the record currently points at.
    /// </summary>
    Task<IReadOnlyList<UserLookup>> LookupAsync(
        string? search, bool activeOnly, int? includeId, int top, CancellationToken cancellationToken = default);

    /// <summary>Inserts the user and returns the generated Id (also set on <paramref name="user"/>).</summary>
    Task<int> CreateAsync(User user, CancellationToken cancellationToken = default);

    /// <summary>Roles and permissions of one user (security.usp_User_GetAccess).</summary>
    Task<UserAccess> GetAccessAsync(int userId, CancellationToken cancellationToken = default);

    /// <summary>
    /// Replaces the user's roles (security.usp_User_SetRoles).
    /// Throws <c>SecurityRuleException</c> 50003 (user not found) or 50004 (last active administrator).
    /// </summary>
    Task SetRolesAsync(int userId, IEnumerable<int> roleIds, int? assignedBy, CancellationToken cancellationToken = default);

    /// <summary>Roles of several users in one query - used to fill the users list.</summary>
    Task<IReadOnlyList<(int UserId, int RoleId, string RoleName)>> GetRolesForUsersAsync(
        IEnumerable<int> userIds, CancellationToken cancellationToken = default);

    /// <summary>Number of active users holding a system role, optionally ignoring one user.</summary>
    Task<int> CountActiveSystemAdminsAsync(int? excludeUserId, CancellationToken cancellationToken = default);

    Task<bool> UpdateProfileAsync(int userId, string fullName, string email, CancellationToken cancellationToken = default);

    /// <summary>
    /// Increments the failed-login counter. When the counter reaches <paramref name="maxAttempts"/> the account
    /// is locked for <paramref name="lockoutMinutes"/> and the counter is reset.
    /// Returns the new counter value and lockout end (if any).
    /// </summary>
    Task<(int FailedLoginAttempts, DateTime? LockoutEndUtc)> RegisterFailedLoginAsync(
        int userId, int maxAttempts, int lockoutMinutes, CancellationToken cancellationToken = default);

    /// <summary>Resets the failed-login counter and stamps LastLoginAtUtc.</summary>
    Task RegisterSuccessfulLoginAsync(int userId, CancellationToken cancellationToken = default);

    Task UpdatePasswordHashAsync(int userId, string passwordHash, CancellationToken cancellationToken = default);

    Task<bool> SetActiveAsync(int userId, bool isActive, CancellationToken cancellationToken = default);
}
