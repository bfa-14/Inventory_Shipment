using System.Globalization;
using System.Security.Claims;
using Microsoft.IdentityModel.JsonWebTokens;

namespace Inventory_Shipment.API.Extensions;

public static class HttpContextExtensions
{
    /// <summary>Numeric user id from the token's "sub" claim.</summary>
    public static int GetUserId(this ClaimsPrincipal principal)
    {
        var value = principal.FindFirstValue(JwtRegisteredClaimNames.Sub)
                    ?? principal.FindFirstValue(ClaimTypes.NameIdentifier);

        return int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var id)
            ? id
            : throw new InvalidOperationException("The access token does not contain a valid user id.");
    }

    public static string? GetClientIp(this HttpContext context)
        => context.Connection.RemoteIpAddress?.ToString();

    public static string? GetUserAgent(this HttpContext context)
        => context.Request.Headers.UserAgent.ToString() is { Length: > 0 } ua ? ua : null;
}
