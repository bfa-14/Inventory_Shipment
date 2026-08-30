using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Auth;
using Inventory_Shipment.Model.DTOs.Users;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Inventory_Shipment.Service.Mapping;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Login / refresh / logout / change-password flows.
/// Security properties:
///  - one generic message for unknown user and wrong password (no account enumeration),
///  - constant-cost verification even when the user does not exist,
///  - lockout after N failed attempts, refresh-token rotation with reuse detection,
///  - every attempt written to security.LoginAudit.
/// </summary>
public sealed class AuthService : IAuthService
{
    private const string InvalidCredentialsMessage = "Invalid username or password.";
    private const string InvalidRefreshTokenMessage = "Invalid or expired refresh token. Please sign in again.";

    private readonly IUserRepository _users;
    private readonly IRefreshTokenRepository _refreshTokens;
    private readonly ILoginAuditRepository _loginAudit;
    private readonly IPasswordHasher _passwordHasher;
    private readonly IPasswordPolicy _passwordPolicy;
    private readonly ITokenService _tokenService;
    private readonly SecurityOptions _security;
    private readonly JwtOptions _jwt;
    private readonly TimeProvider _timeProvider;
    private readonly ILogger<AuthService> _logger;

    public AuthService(
        IUserRepository users,
        IRefreshTokenRepository refreshTokens,
        ILoginAuditRepository loginAudit,
        IPasswordHasher passwordHasher,
        IPasswordPolicy passwordPolicy,
        ITokenService tokenService,
        IOptions<SecurityOptions> securityOptions,
        IOptions<JwtOptions> jwtOptions,
        TimeProvider timeProvider,
        ILogger<AuthService> logger)
    {
        _users = users;
        _refreshTokens = refreshTokens;
        _loginAudit = loginAudit;
        _passwordHasher = passwordHasher;
        _passwordPolicy = passwordPolicy;
        _tokenService = tokenService;
        _security = securityOptions.Value;
        _jwt = jwtOptions.Value;
        _timeProvider = timeProvider;
        _logger = logger;
    }

    private DateTime UtcNow => _timeProvider.GetUtcNow().UtcDateTime;

    public async Task<Result<AuthResponse>> LoginAsync(LoginRequest request, string? ipAddress, string? userAgent,
        CancellationToken cancellationToken = default)
    {
        var identifier = request.Username.Trim();
        var now = UtcNow;

        var user = await _users.GetByUsernameOrEmailAsync(identifier, cancellationToken);

        if (user is null)
        {
            _passwordHasher.SimulateVerify(request.Password);
            await AuditAsync(identifier, null, false, "UnknownUser", ipAddress, userAgent, cancellationToken);
            _logger.LogWarning("Login failed: unknown user {Username} from {IpAddress}", identifier, ipAddress);
            return Result<AuthResponse>.Failure(ErrorType.Unauthorized, InvalidCredentialsMessage);
        }

        if (user.IsLockedOut(now))
        {
            await AuditAsync(identifier, user.Id, false, "LockedOut", ipAddress, userAgent, cancellationToken);
            _logger.LogWarning("Login rejected: user {UserId} is locked out until {LockoutEnd}", user.Id, user.LockoutEndUtc);
            return Result<AuthResponse>.Failure(ErrorType.Locked, LockedMessage(user.LockoutEndUtc!.Value, now));
        }

        if (!_passwordHasher.Verify(request.Password, user.PasswordHash))
        {
            var (attempts, lockoutEnd) = await _users.RegisterFailedLoginAsync(
                user.Id, _security.MaxFailedLoginAttempts, _security.LockoutMinutes, cancellationToken);

            var lockedNow = lockoutEnd.HasValue && lockoutEnd.Value > now;
            await AuditAsync(identifier, user.Id, false, lockedNow ? "WrongPassword_LockedOut" : "WrongPassword",
                ipAddress, userAgent, cancellationToken);

            if (lockedNow)
            {
                _logger.LogWarning("User {UserId} locked out until {LockoutEnd} after {Max} failed attempts (from {IpAddress})",
                    user.Id, lockoutEnd, _security.MaxFailedLoginAttempts, ipAddress);
                return Result<AuthResponse>.Failure(ErrorType.Locked, LockedMessage(lockoutEnd!.Value, now));
            }

            _logger.LogWarning("Login failed: wrong password for user {UserId} ({Attempts}/{Max}) from {IpAddress}",
                user.Id, attempts, _security.MaxFailedLoginAttempts, ipAddress);
            return Result<AuthResponse>.Failure(ErrorType.Unauthorized, InvalidCredentialsMessage);
        }

        if (!user.IsActive)
        {
            await AuditAsync(identifier, user.Id, false, "Inactive", ipAddress, userAgent, cancellationToken);
            _logger.LogWarning("Login rejected: user {UserId} is deactivated", user.Id);
            return Result<AuthResponse>.Failure(ErrorType.Forbidden,
                "This account has been deactivated. Please contact an administrator.");
        }

        await _users.RegisterSuccessfulLoginAsync(user.Id, cancellationToken);
        user.LastLoginAtUtc = now;

        if (_passwordHasher.NeedsRehash(user.PasswordHash))
        {
            // Transparently upgrade hashes created with older/weaker Argon2 parameters.
            await _users.UpdatePasswordHashAsync(user.Id, _passwordHasher.Hash(request.Password), cancellationToken);
        }

        var (rawRefreshToken, refreshToken) = BuildRefreshToken(user.Id, ipAddress, now);
        await _refreshTokens.CreateAsync(refreshToken, cancellationToken);

        await AuditAsync(identifier, user.Id, true, null, ipAddress, userAgent, cancellationToken);
        _logger.LogInformation("User {UserId} ({Username}) signed in from {IpAddress}", user.Id, user.Username, ipAddress);

        return Result<AuthResponse>.Success(await BuildResponseAsync(user, rawRefreshToken, refreshToken, cancellationToken));
    }

    public async Task<Result<AuthResponse>> RefreshAsync(string refreshToken, string? ipAddress,
        CancellationToken cancellationToken = default)
    {
        var tokenHash = _tokenService.HashToken(refreshToken);
        var stored = await _refreshTokens.GetByTokenHashAsync(tokenHash, cancellationToken);
        var now = UtcNow;

        if (stored is null)
        {
            return Result<AuthResponse>.Failure(ErrorType.Unauthorized, InvalidRefreshTokenMessage);
        }

        if (stored.IsRevoked)
        {
            // A token that was already rotated/revoked is being presented again: treat it as stolen
            // and invalidate every session of this user.
            var revoked = await _refreshTokens.RevokeAllForUserAsync(stored.UserId, ipAddress,
                "Reuse of a revoked refresh token detected", cancellationToken);
            _logger.LogWarning("Refresh token reuse detected for user {UserId} from {IpAddress}; revoked {Count} token(s)",
                stored.UserId, ipAddress, revoked);
            return Result<AuthResponse>.Failure(ErrorType.Unauthorized, InvalidRefreshTokenMessage);
        }

        if (stored.IsExpired(now))
        {
            return Result<AuthResponse>.Failure(ErrorType.Unauthorized, InvalidRefreshTokenMessage);
        }

        var user = await _users.GetByIdAsync(stored.UserId, cancellationToken);
        if (user is null || !user.IsActive)
        {
            return Result<AuthResponse>.Failure(ErrorType.Unauthorized, "This account is no longer available.");
        }

        if (user.IsLockedOut(now))
        {
            return Result<AuthResponse>.Failure(ErrorType.Locked, LockedMessage(user.LockoutEndUtc!.Value, now));
        }

        var (rawNewToken, newToken) = BuildRefreshToken(user.Id, ipAddress, now);
        var rotated = await _refreshTokens.RotateAsync(tokenHash, newToken, ipAddress, cancellationToken);

        if (!rotated)
        {
            // Lost a race with another refresh using the same token - same treatment as reuse.
            await _refreshTokens.RevokeAllForUserAsync(user.Id, ipAddress,
                "Concurrent refresh with the same token", cancellationToken);
            _logger.LogWarning("Concurrent refresh-token rotation for user {UserId} from {IpAddress}", user.Id, ipAddress);
            return Result<AuthResponse>.Failure(ErrorType.Unauthorized, InvalidRefreshTokenMessage);
        }

        return Result<AuthResponse>.Success(await BuildResponseAsync(user, rawNewToken, newToken, cancellationToken));
    }

    public async Task<Result> LogoutAsync(string refreshToken, string? ipAddress, CancellationToken cancellationToken = default)
    {
        var tokenHash = _tokenService.HashToken(refreshToken);
        await _refreshTokens.RevokeAsync(tokenHash, ipAddress, "Logged out", cancellationToken);
        return Result.Success();
    }

    public async Task<Result> LogoutAllAsync(int userId, string? ipAddress, CancellationToken cancellationToken = default)
    {
        var revoked = await _refreshTokens.RevokeAllForUserAsync(userId, ipAddress, "Logged out from all devices", cancellationToken);
        _logger.LogInformation("User {UserId} signed out everywhere ({Count} token(s) revoked)", userId, revoked);
        return Result.Success();
    }

    public async Task<Result<UserDto>> GetCurrentUserAsync(int userId, CancellationToken cancellationToken = default)
    {
        var user = await _users.GetByIdAsync(userId, cancellationToken);
        if (user is null)
        {
            return Result<UserDto>.Failure(ErrorType.NotFound, "User not found.");
        }

        var access = await _users.GetAccessAsync(userId, cancellationToken);
        return Result<UserDto>.Success(user.ToDto(access));
    }

    public async Task<Result> ChangePasswordAsync(int userId, ChangePasswordRequest request, string? ipAddress,
        CancellationToken cancellationToken = default)
    {
        var user = await _users.GetByIdAsync(userId, cancellationToken);
        if (user is null)
        {
            return Result.Failure(ErrorType.NotFound, "User not found.");
        }

        if (!_passwordHasher.Verify(request.CurrentPassword, user.PasswordHash))
        {
            _logger.LogWarning("Password change rejected for user {UserId}: current password incorrect", userId);
            return Result.Failure(ErrorType.Unauthorized, "The current password is incorrect.");
        }

        if (request.NewPassword == request.CurrentPassword)
        {
            return Result.Failure(ErrorType.Validation, "The new password must be different from the current password.");
        }

        var errors = _passwordPolicy.Validate(request.NewPassword);
        if (errors.Count > 0)
        {
            return Result.Failure(ErrorType.Validation, "The new password does not meet the password policy.", errors);
        }

        await _users.UpdatePasswordHashAsync(userId, _passwordHasher.Hash(request.NewPassword), cancellationToken);
        await _refreshTokens.RevokeAllForUserAsync(userId, ipAddress, "Password changed", cancellationToken);

        _logger.LogInformation("User {UserId} changed their password; all refresh tokens revoked", userId);
        return Result.Success();
    }

    // ----- helpers -----

    private (string RawToken, RefreshToken Entity) BuildRefreshToken(int userId, string? ipAddress, DateTime now)
    {
        var raw = _tokenService.GenerateRefreshToken();
        var entity = new RefreshToken
        {
            UserId = userId,
            TokenHash = _tokenService.HashToken(raw),
            ExpiresAtUtc = now.AddDays(_jwt.RefreshTokenDays),
            CreatedAtUtc = now,
            CreatedByIp = ipAddress
        };
        return (raw, entity);
    }

    private async Task<AuthResponse> BuildResponseAsync(User user, string rawRefreshToken, RefreshToken refreshToken,
        CancellationToken cancellationToken)
    {
        var access = await _users.GetAccessAsync(user.Id, cancellationToken);
        var (accessToken, accessExpires) = _tokenService.CreateAccessToken(user, access);

        return new AuthResponse
        {
            AccessToken = accessToken,
            AccessTokenExpiresAtUtc = accessExpires.AsUtc(),
            RefreshToken = rawRefreshToken,
            RefreshTokenExpiresAtUtc = refreshToken.ExpiresAtUtc.AsUtc(),
            User = user.ToDto(access)
        };
    }

    private static string LockedMessage(DateTime lockoutEndUtc, DateTime now)
    {
        var minutes = Math.Max(1, (int)Math.Ceiling((lockoutEndUtc - now).TotalMinutes));
        return $"This account is temporarily locked because of too many failed sign-in attempts. Try again in {minutes} minute(s).";
    }

    private async Task AuditAsync(string username, int? userId, bool succeeded, string? failureReason,
        string? ipAddress, string? userAgent, CancellationToken cancellationToken)
    {
        try
        {
            await _loginAudit.AddAsync(new LoginAudit
            {
                Username = Truncate(username, 256) ?? string.Empty,
                UserId = userId,
                Succeeded = succeeded,
                FailureReason = failureReason,
                IpAddress = Truncate(ipAddress, 45),
                UserAgent = Truncate(userAgent, 512),
                AttemptedAtUtc = UtcNow
            }, cancellationToken);
        }
        catch (Exception ex)
        {
            // Auditing must never break the login itself.
            _logger.LogError(ex, "Failed to write login audit entry for {Username}", username);
        }
    }

    private static string? Truncate(string? value, int maxLength)
        => value is null || value.Length <= maxLength ? value : value[..maxLength];
}
