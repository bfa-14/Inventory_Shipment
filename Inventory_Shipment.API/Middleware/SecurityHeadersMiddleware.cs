namespace Inventory_Shipment.API.Middleware;

/// <summary>
/// Adds defensive HTTP response headers to every response. The API serves JSON only, so the
/// Content-Security-Policy is deliberately strict; it is relaxed for the API docs UI under /scalar,
/// which needs inline scripts and styles.
/// </summary>
public sealed class SecurityHeadersMiddleware
{
    private const string StrictCsp = "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

    private readonly RequestDelegate _next;

    public SecurityHeadersMiddleware(RequestDelegate next)
    {
        _next = next;
    }

    public Task InvokeAsync(HttpContext context)
    {
        var headers = context.Response.Headers;

        headers["X-Content-Type-Options"] = "nosniff";
        headers["X-Frame-Options"] = "DENY";
        headers["Referrer-Policy"] = "no-referrer";
        headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()";

        if (context.Request.Path.StartsWithSegments("/api"))
        {
            // Tokens and user data must never be cached by browsers or proxies.
            headers["Cache-Control"] = "no-store";
        }

        if (!context.Request.Path.StartsWithSegments("/scalar"))
        {
            headers["Content-Security-Policy"] = StrictCsp;
        }

        return _next(context);
    }
}

public static class SecurityHeadersMiddlewareExtensions
{
    public static IApplicationBuilder UseSecurityHeaders(this IApplicationBuilder app)
        => app.UseMiddleware<SecurityHeadersMiddleware>();
}
