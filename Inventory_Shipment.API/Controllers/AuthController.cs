using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Auth;
using Inventory_Shipment.Model.DTOs.Users;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;

namespace Inventory_Shipment.API.Controllers;

/// <summary>Sign-in, token refresh, sign-out and password management for the current user.</summary>
[ApiController]
[Route("api/auth")]
[Produces("application/json")]
public sealed class AuthController : ControllerBase
{
    private readonly IAuthService _authService;

    public AuthController(IAuthService authService)
    {
        _authService = authService;
    }

    /// <summary>Signs in with username (or e-mail) and password. Returns an access token and a refresh token.</summary>
    [HttpPost("login")]
    [AllowAnonymous]
    [EnableRateLimiting(AuthenticationExtensions.AuthRateLimitPolicy)]
    [ProducesResponseType<AuthResponse>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status401Unauthorized)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status403Forbidden)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status423Locked)]
    [ProducesResponseType(StatusCodes.Status429TooManyRequests)]
    public async Task<ActionResult<AuthResponse>> Login([FromBody] LoginRequest request, CancellationToken cancellationToken)
    {
        var result = await _authService.LoginAsync(request, HttpContext.GetClientIp(), HttpContext.GetUserAgent(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Exchanges a valid refresh token for a new access token + refresh token (the old one is revoked).</summary>
    [HttpPost("refresh")]
    [AllowAnonymous]
    [EnableRateLimiting(AuthenticationExtensions.AuthRateLimitPolicy)]
    [ProducesResponseType<AuthResponse>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status401Unauthorized)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status423Locked)]
    public async Task<ActionResult<AuthResponse>> Refresh([FromBody] RefreshTokenRequest request, CancellationToken cancellationToken)
    {
        var result = await _authService.RefreshAsync(request.RefreshToken, HttpContext.GetClientIp(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Revokes the given refresh token (sign out on this device).</summary>
    [HttpPost("logout")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    public async Task<ActionResult> Logout([FromBody] LogoutRequest request, CancellationToken cancellationToken)
    {
        var result = await _authService.LogoutAsync(request.RefreshToken, HttpContext.GetClientIp(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    /// <summary>Revokes every refresh token of the current user (sign out everywhere).</summary>
    [HttpPost("logout-all")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    public async Task<ActionResult> LogoutAll(CancellationToken cancellationToken)
    {
        var result = await _authService.LogoutAllAsync(User.GetUserId(), HttpContext.GetClientIp(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    /// <summary>Returns the profile of the signed-in user.</summary>
    [HttpGet("me")]
    [ProducesResponseType<UserDto>(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status401Unauthorized)]
    public async Task<ActionResult<UserDto>> Me(CancellationToken cancellationToken)
    {
        var result = await _authService.GetCurrentUserAsync(User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Changes the signed-in user's password. All refresh tokens are revoked afterwards.</summary>
    [HttpPost("change-password")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status401Unauthorized)]
    public async Task<ActionResult> ChangePassword([FromBody] ChangePasswordRequest request, CancellationToken cancellationToken)
    {
        var result = await _authService.ChangePasswordAsync(User.GetUserId(), request, HttpContext.GetClientIp(), cancellationToken);
        return result.ToNoContentResult(this);
    }
}
