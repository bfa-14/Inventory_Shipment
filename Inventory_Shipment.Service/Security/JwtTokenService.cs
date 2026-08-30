using System.Buffers.Text;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace Inventory_Shipment.Service.Security;

public sealed class JwtTokenService : ITokenService
{
    /// <summary>Claim type used for roles (the API's RoleClaimType is configured to match).</summary>
    public const string RoleClaimType = "role";

    private const int RefreshTokenBytes = 64;

    private readonly JwtOptions _options;
    private readonly TimeProvider _timeProvider;
    private readonly SigningCredentials _signingCredentials;
    private readonly JsonWebTokenHandler _handler = new();

    public JwtTokenService(IOptions<JwtOptions> options, TimeProvider timeProvider)
    {
        _options = options.Value;
        _timeProvider = timeProvider;

        var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(_options.SecretKey));
        _signingCredentials = new SigningCredentials(key, SecurityAlgorithms.HmacSha256);
    }

    public (string Token, DateTime ExpiresAtUtc) CreateAccessToken(User user, UserAccess access)
    {
        var now = _timeProvider.GetUtcNow().UtcDateTime;
        var expires = now.AddMinutes(_options.AccessTokenMinutes);

        var descriptor = new SecurityTokenDescriptor
        {
            Issuer = _options.Issuer,
            Audience = _options.Audience,
            IssuedAt = now,
            NotBefore = now,
            Expires = expires,
            SigningCredentials = _signingCredentials,
            Claims = new Dictionary<string, object>
            {
                [JwtRegisteredClaimNames.Sub] = user.Id.ToString(CultureInfo.InvariantCulture),
                [JwtRegisteredClaimNames.UniqueName] = user.Username,
                [JwtRegisteredClaimNames.Email] = user.Email,
                [JwtRegisteredClaimNames.Name] = user.FullName,
                [JwtRegisteredClaimNames.Jti] = Guid.NewGuid().ToString("N"),
                // A collection value emits one claim per element.
                [RoleClaimType] = access.Roles.Select(r => r.Name).ToArray(),
                [Permissions.ClaimType] = access.Permissions.ToArray()
            }
        };

        return (_handler.CreateToken(descriptor), expires);
    }

    public string GenerateRefreshToken()
        => Base64Url.EncodeToString(RandomNumberGenerator.GetBytes(RefreshTokenBytes));

    public string HashToken(string token)
        => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token)));
}
