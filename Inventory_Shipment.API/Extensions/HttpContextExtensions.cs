using System.Globalization;
using System.Security.Claims;
using Inventory_Shipment.Model.Security;
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

    /// <summary>
    /// Every permission code in the token.
    ///
    /// READ FROM THE TOKEN AND NOT FROM THE REQUEST, which is the whole point: an endpoint that
    /// behaves differently for a privileged caller (an import honouring a manual price, say) has to
    /// ask what the caller HOLDS, and a flag on the request body would be the caller answering that
    /// question about themselves.
    ///
    /// A set, because the callers ask "does it contain" — one claim per permission means a list
    /// scan per question otherwise, on tokens that carry dozens.
    /// </summary>
    public static IReadOnlySet<string> GetPermissions(this ClaimsPrincipal principal)
        => principal.FindAll(Permissions.ClaimType)
            .Select(c => c.Value)
            .ToHashSet(StringComparer.Ordinal);

    public static string? GetClientIp(this HttpContext context)
        => context.Connection.RemoteIpAddress?.ToString();

    public static string? GetUserAgent(this HttpContext context)
        => context.Request.Headers.UserAgent.ToString() is { Length: > 0 } ua ? ua : null;
}
