namespace Inventory_Shipment.API.Middleware;

/// <summary>
/// A REQUEST THE CLIENT GAVE UP ON IS NOT A FAILURE. When the browser aborts a call (a list reloaded while its previous
/// search still runs, a page left), the request's cancellation token stops the SQL command, and SqlClient throws a
/// SqlException ("Operation cancelled by user"), not an OperationCanceledException. The exception handler then logged
/// it as an unhandled failure, which hides the real ones in the log. Any exception thrown once
/// <see cref="HttpContext.RequestAborted"/> is cancelled is answered 499 and logged at Information: nobody is waiting
/// for the answer, and nothing went wrong on the server.
/// </summary>
public sealed class ClientAbortMiddleware
{
    private readonly RequestDelegate _next;
    private readonly ILogger<ClientAbortMiddleware> _logger;

    public ClientAbortMiddleware(RequestDelegate next, ILogger<ClientAbortMiddleware> logger)
    {
        _next = next;
        _logger = logger;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        try
        {
            await _next(context);
        }
        catch (Exception ex) when (context.RequestAborted.IsCancellationRequested)
        {
            _logger.LogInformation(
                "Request {Method} {Path} aborted by the client ({ExceptionType}).",
                context.Request.Method, context.Request.Path, ex.GetType().Name);
            if (!context.Response.HasStarted)
            {
                context.Response.StatusCode = StatusCodes.Status499ClientClosedRequest;
            }
        }
    }
}

public static class ClientAbortMiddlewareExtensions
{
    public static IApplicationBuilder UseClientAbort(this IApplicationBuilder app)
        => app.UseMiddleware<ClientAbortMiddleware>();
}
