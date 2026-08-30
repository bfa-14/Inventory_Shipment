using System.Text;
using System.Threading.RateLimiting;
using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Service.Security;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace Inventory_Shipment.API.Extensions;

public static class AuthenticationExtensions
{
    /// <summary>Name of the rate-limiting policy applied to login/refresh.</summary>
    public const string AuthRateLimitPolicy = "auth";

    public static IServiceCollection AddJwtAuthentication(this IServiceCollection services, IConfiguration configuration)
    {
        var jwt = configuration.GetSection(JwtOptions.SectionName).Get<JwtOptions>() ?? new JwtOptions();

        services
            .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddJwtBearer(options =>
            {
                // Keep the original JWT claim names ("sub", "role", ...) instead of the legacy SOAP-style URIs.
                options.MapInboundClaims = false;
                options.SaveToken = false;

                options.TokenValidationParameters = new TokenValidationParameters
                {
                    ValidateIssuer = true,
                    ValidIssuer = jwt.Issuer,
                    ValidateAudience = true,
                    ValidAudience = jwt.Audience,
                    ValidateIssuerSigningKey = true,
                    IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwt.SecretKey)),
                    ValidAlgorithms = [SecurityAlgorithms.HmacSha256],
                    ValidateLifetime = true,
                    RequireExpirationTime = true,
                    ClockSkew = TimeSpan.FromSeconds(30),
                    NameClaimType = JwtRegisteredClaimNames.UniqueName,
                    RoleClaimType = JwtTokenService.RoleClaimType
                };
            });

        services.AddAuthorization(options =>
        {
            // Secure by default: every endpoint requires a valid token unless it opts out with [AllowAnonymous].
            options.FallbackPolicy = new AuthorizationPolicyBuilder()
                .RequireAuthenticatedUser()
                .Build();
        });

        // Materialises the "Permission:<code>" policies used by [HasPermission].
        services.AddSingleton<IAuthorizationPolicyProvider, PermissionPolicyProvider>();
        services.AddSingleton<IAuthorizationHandler, PermissionAuthorizationHandler>();

        return services;
    }

    /// <summary>Per-client-IP fixed-window limit for the login and refresh endpoints (brute-force protection).</summary>
    public static IServiceCollection AddAuthRateLimiting(this IServiceCollection services, IConfiguration configuration)
    {
        var limits = configuration.GetSection(SecurityOptions.SectionName).Get<SecurityOptions>()?.LoginRateLimit
                     ?? new RateLimitOptions();

        services.AddRateLimiter(options =>
        {
            options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;

            options.AddPolicy(AuthRateLimitPolicy, httpContext =>
                RateLimitPartition.GetFixedWindowLimiter(
                    partitionKey: httpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown",
                    factory: _ => new FixedWindowRateLimiterOptions
                    {
                        PermitLimit = limits.PermitLimit,
                        Window = TimeSpan.FromSeconds(limits.WindowSeconds),
                        QueueLimit = 0
                    }));

            options.OnRejected = async (context, cancellationToken) =>
            {
                context.HttpContext.Response.Headers.RetryAfter = limits.WindowSeconds.ToString();
                await context.HttpContext.Response.WriteAsJsonAsync(new
                {
                    title = "Too many requests",
                    status = StatusCodes.Status429TooManyRequests,
                    detail = "Too many sign-in attempts from this address. Please wait and try again."
                }, cancellationToken);
            };
        });

        return services;
    }
}
