using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Users;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Inventory_Shipment.Service.Mapping;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

public sealed class UserService : IUserService
{
    private const string ChooseWarehousesMessage = "Choose All warehouses, or tick the warehouses this user may use.";

    private readonly IUserRepository _users;
    private readonly IUserWarehouseRepository _userWarehouses;
    private readonly IRefreshTokenRepository _refreshTokens;
    private readonly IPasswordHasher _passwordHasher;
    private readonly IPasswordPolicy _passwordPolicy;
    private readonly ILogger<UserService> _logger;

    public UserService(
        IUserRepository users,
        IUserWarehouseRepository userWarehouses,
        IRefreshTokenRepository refreshTokens,
        IPasswordHasher passwordHasher,
        IPasswordPolicy passwordPolicy,
        ILogger<UserService> logger)
    {
        _users = users;
        _userWarehouses = userWarehouses;
        _refreshTokens = refreshTokens;
        _passwordHasher = passwordHasher;
        _passwordPolicy = passwordPolicy;
        _logger = logger;
    }

    public async Task<Result<IReadOnlyList<UserDto>>> GetAllAsync(CancellationToken cancellationToken = default)
    {
        var users = await _users.GetAllAsync(cancellationToken);
        if (users.Count == 0)
        {
            return Result<IReadOnlyList<UserDto>>.Success([]);
        }

        // One extra query for every user's roles instead of one per row.
        var roleRows = await _users.GetRolesForUsersAsync(users.Select(u => u.Id), cancellationToken);
        var rolesByUser = roleRows
            .GroupBy(r => r.UserId)
            .ToDictionary(g => g.Key, g => (IReadOnlyList<(int Id, string Name)>)g.Select(r => (r.RoleId, r.RoleName)).ToList());

        // (92) And one for every user's warehouse access: the list's Warehouses column.
        var summaries = await _userWarehouses.SummariesAsync(cancellationToken);
        var flagsByUser = summaries.Users.GroupBy(f => f.UserId).ToDictionary(g => g.Key, g => g.First());
        var ticksByUser = summaries.Ticks
            .GroupBy(t => t.UserId)
            .ToDictionary(g => g.Key, g => (IReadOnlyList<UserWarehouseRefDto>)g.Select(t => new UserWarehouseRefDto
            {
                Id = t.WarehouseId,
                Code = t.WarehouseCode,
                Name = t.WarehouseName,
                BranchCode = t.BranchCode,
                IsActive = t.IsActive,
                HasChildren = t.ChildCount > 0,
            }).ToList());

        var dtos = users
            .Select(u =>
            {
                var dto = rolesByUser.TryGetValue(u.Id, out var roles) ? u.ToDto().WithRoles(roles) : u.ToDto();
                var flags = flagsByUser.GetValueOrDefault(u.Id);
                return dto.WithWarehouses(
                    flags?.AllWarehouses ?? u.AllWarehouses,
                    flags?.IsSystemAdministrator ?? false,
                    ticksByUser.GetValueOrDefault(u.Id) ?? []);
            })
            .ToList();

        return Result<IReadOnlyList<UserDto>>.Success(dtos);
    }

    public async Task<Result<UserDto>> GetByIdAsync(int id, CancellationToken cancellationToken = default)
    {
        var user = await _users.GetByIdAsync(id, cancellationToken);
        if (user is null)
        {
            return Result<UserDto>.Failure(ErrorType.NotFound, "User not found.");
        }

        var access = await _users.GetAccessAsync(id, cancellationToken);
        return Result<UserDto>.Success(user.ToDto(access));
    }

    public async Task<Result<IReadOnlyList<UserLookupDto>>> LookupAsync(
        string? search, bool activeOnly, int? includeId, int top, CancellationToken cancellationToken = default)
    {
        var users = await _users.LookupAsync(search, activeOnly, includeId, top, cancellationToken);
        return Result<IReadOnlyList<UserLookupDto>>.Success(users.Select(u => u.ToDto()).ToList());
    }

    public async Task<Result<UserDto>> CreateAsync(CreateUserRequest request, int actingUserId, CancellationToken cancellationToken = default)
    {
        var errors = _passwordPolicy.Validate(request.Password);
        if (errors.Count > 0)
        {
            return Result<UserDto>.Failure(ErrorType.Validation, "The password does not meet the password policy.", errors);
        }

        var username = request.Username.Trim();
        var email = request.Email.Trim();

        if (await _users.UsernameExistsAsync(username, cancellationToken))
        {
            return Result<UserDto>.Failure(ErrorType.Conflict, "That username is already taken.");
        }

        if (await _users.EmailExistsAsync(email, cancellationToken))
        {
            return Result<UserDto>.Failure(ErrorType.Conflict, "That e-mail address is already registered.");
        }

        var user = new User
        {
            Username = username,
            Email = email,
            FullName = request.FullName.Trim(),
            PasswordHash = _passwordHasher.Hash(request.Password),
            IsActive = true
        };

        try
        {
            await _users.CreateAsync(user, cancellationToken);
        }
        catch (DuplicateRecordException)
        {
            // Lost a race with a concurrent insert of the same username/e-mail.
            return Result<UserDto>.Failure(ErrorType.Conflict, "A user with that username or e-mail already exists.");
        }

        if (request.RoleIds.Length > 0)
        {
            try
            {
                await _users.SetRolesAsync(user.Id, request.RoleIds, actingUserId, cancellationToken);
            }
            catch (SecurityRuleException ex)
            {
                return Result<UserDto>.Failure(MapRuleError(ex), ex.Message);
            }
        }

        var created = await _users.GetByIdAsync(user.Id, cancellationToken) ?? user;
        var access = await _users.GetAccessAsync(user.Id, cancellationToken);

        _logger.LogInformation("User {UserId} ({Username}) created with {Count} role(s) by user {ActingUserId}",
            created.Id, created.Username, request.RoleIds.Length, actingUserId);

        return Result<UserDto>.Success(created.ToDto(access));
    }

    public async Task<Result> UpdateAsync(int id, UpdateUserRequest request, CancellationToken cancellationToken = default)
    {
        var user = await _users.GetByIdAsync(id, cancellationToken);
        if (user is null)
        {
            return Result.Failure(ErrorType.NotFound, "User not found.");
        }

        var email = request.Email.Trim();

        if (await _users.EmailExistsForOtherUserAsync(email, id, cancellationToken))
        {
            return Result.Failure(ErrorType.Conflict, "That e-mail address is already registered.");
        }

        try
        {
            if (!await _users.UpdateProfileAsync(id, request.FullName.Trim(), email, cancellationToken))
            {
                return Result.Failure(ErrorType.NotFound, "User not found.");
            }
        }
        catch (DuplicateRecordException)
        {
            return Result.Failure(ErrorType.Conflict, "That e-mail address is already registered.");
        }

        _logger.LogInformation("Profile of user {UserId} updated", id);
        return Result.Success();
    }

    public async Task<Result> SetRolesAsync(int id, IEnumerable<int> roleIds, int actingUserId, CancellationToken cancellationToken = default)
    {
        try
        {
            await _users.SetRolesAsync(id, roleIds, actingUserId, cancellationToken);
        }
        catch (SecurityRuleException ex)
        {
            return Result.Failure(MapRuleError(ex), ex.Message);
        }

        _logger.LogInformation("Roles of user {UserId} replaced by user {ActingUserId}", id, actingUserId);
        return Result.Success();
    }

    public async Task<Result> SetActiveAsync(int id, bool isActive, int actingUserId, CancellationToken cancellationToken = default)
    {
        if (id == actingUserId && !isActive)
        {
            return Result.Failure(ErrorType.Validation, "You cannot deactivate your own account.");
        }

        // Deactivating the only remaining administrator would lock everyone out of the security module.
        if (!isActive && await _users.CountActiveSystemAdminsAsync(id, cancellationToken) == 0)
        {
            return Result.Failure(ErrorType.Validation, "Cannot deactivate the last active administrator.");
        }

        var updated = await _users.SetActiveAsync(id, isActive, cancellationToken);
        if (!updated)
        {
            return Result.Failure(ErrorType.NotFound, "User not found.");
        }

        if (!isActive)
        {
            await _refreshTokens.RevokeAllForUserAsync(id, null, "Account deactivated", cancellationToken);
        }

        _logger.LogInformation("User {UserId} {Action} by user {ActingUserId}", id, isActive ? "activated" : "deactivated", actingUserId);
        return Result.Success();
    }

    public async Task<Result> ResetPasswordAsync(int id, string newPassword, CancellationToken cancellationToken = default)
    {
        var user = await _users.GetByIdAsync(id, cancellationToken);
        if (user is null)
        {
            return Result.Failure(ErrorType.NotFound, "User not found.");
        }

        var errors = _passwordPolicy.Validate(newPassword);
        if (errors.Count > 0)
        {
            return Result.Failure(ErrorType.Validation, "The password does not meet the password policy.", errors);
        }

        await _users.UpdatePasswordHashAsync(id, _passwordHasher.Hash(newPassword), cancellationToken);
        await _refreshTokens.RevokeAllForUserAsync(id, null, "Password reset by administrator", cancellationToken);

        _logger.LogInformation("Password reset for user {UserId}; all refresh tokens revoked", id);
        return Result.Success();
    }

    /* ── (92) warehouse access ─────────────────────────────────────────────────────────────────── */

    public async Task<Result<UserWarehousesDto>> GetWarehousesAsync(int id, CancellationToken cancellationToken = default)
    {
        try
        {
            return Result<UserWarehousesDto>.Success(await _userWarehouses.GetAsync(id, cancellationToken));
        }
        catch (SecurityRuleException ex)
        {
            return Result<UserWarehousesDto>.Failure(MapRuleError(ex), ex.Message, RuleCode(ex));
        }
    }

    /// <summary>
    /// All warehouses, or only the ticked ones (a ticked parent gives its whole tree). Takes effect at once: nothing is
    /// cached and no token carries it (M8). The last save wins; the history keeps every change. Answers the dialog re-read.
    /// </summary>
    public async Task<Result<UserWarehousesDto>> SetWarehousesAsync(
        int id, SetUserWarehousesRequest request, int actingUserId, CancellationToken cancellationToken = default)
    {
        if (request.AllWarehouses is not { } allWarehouses)
        {
            return Result<UserWarehousesDto>.Failure(ErrorType.Validation, ChooseWarehousesMessage, "VALIDATION");
        }

        try
        {
            await _userWarehouses.SetAsync(id, allWarehouses, request.WarehouseIds ?? [], actingUserId, cancellationToken);
            var saved = await _userWarehouses.GetAsync(id, cancellationToken);

            // The words of the history (security.fn_User_WarehouseAccessText), for the log only.
            var after = saved.AllWarehouses
                ? "All warehouses"
                : "Only: " + (saved.Warehouses.Count == 0 ? "none" : string.Join(", ", saved.Warehouses.Select(w => w.Code)));
            _logger.LogInformation("Warehouses of user {UserId} set by user {ActingUserId}: {After}", id, actingUserId, after);

            return Result<UserWarehousesDto>.Success(saved);
        }
        catch (SecurityRuleException ex)
        {
            return Result<UserWarehousesDto>.Failure(MapRuleError(ex), ex.Message, RuleCode(ex));
        }
    }

    /// <summary>(92) The ProblemDetails code of a security procedure's refusal, as the pages read it.</summary>
    private static string RuleCode(SecurityRuleException ex) => MapRuleError(ex) switch
    {
        ErrorType.NotFound => "NOT_FOUND",
        _ => "VALIDATION",
    };

    private static ErrorType MapRuleError(SecurityRuleException ex) => ex.Code switch
    {
        SqlErrors.UserNotFound => ErrorType.NotFound,
        SqlErrors.RoleNotFound => ErrorType.NotFound,
        SqlErrors.LastAdministrator => ErrorType.Validation,
        SqlErrors.UserWarehousesValidation => ErrorType.Validation,
        _ => ErrorType.Validation
    };
}
