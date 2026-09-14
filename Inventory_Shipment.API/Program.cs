using System.Text.Json.Serialization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.API.Middleware;
using Inventory_Shipment.API.OpenApi;
using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Repository;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Service;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;
using Scalar.AspNetCore;

var builder = WebApplication.CreateBuilder(args);

// ----- Configuration (validated at start-up so misconfiguration fails fast) -----
builder.Services.AddOptions<JwtOptions>()
    .Bind(builder.Configuration.GetSection(JwtOptions.SectionName))
    .ValidateDataAnnotations()
    .ValidateOnStart();

builder.Services.AddOptions<SecurityOptions>()
    .Bind(builder.Configuration.GetSection(SecurityOptions.SectionName))
    .ValidateDataAnnotations()
    .ValidateOnStart();

builder.Services.AddOptions<SeedOptions>()
    .Bind(builder.Configuration.GetSection(SeedOptions.SectionName));

builder.Services.AddOptions<SalesOptions>()
    .Bind(builder.Configuration.GetSection(SalesOptions.SectionName));

builder.Services.AddOptions<PurchaseOptions>()
    .Bind(builder.Configuration.GetSection(PurchaseOptions.SectionName));

// ----- Layers -----
var connectionString = builder.Configuration.GetConnectionString("DefaultConnection")
    ?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing from configuration.");

builder.Services.AddRepositoryLayer(options =>
{
    builder.Configuration.GetSection(DatabaseOptions.SectionName).Bind(options);
    options.ConnectionString = connectionString;
});
builder.Services.AddServiceLayer();

// ----- Web -----
builder.Services.AddControllers()
    .AddJsonOptions(options =>
    {
        options.JsonSerializerOptions.Converters.Add(new JsonStringEnumConverter());
    })
    .ConfigureApiBehaviorOptions(options =>
    {
        // A REQUEST THE MODEL BINDER REFUSES GETS THE SAME SHAPE AS ONE A PROCEDURE REFUSES. The
        // default answer is a ValidationProblemDetails with an "errors" map and no code, so a client
        // routing on "code" (VALIDATION, NO_PRICE, INSUFFICIENT_STOCK, ...) would have to special-case
        // it. The map stays; a code and a one-line detail naming the first field are added on top.
        options.InvalidModelStateResponseFactory = context =>
        {
            var problem = new ValidationProblemDetails(context.ModelState)
            {
                Status = StatusCodes.Status400BadRequest,
                Title = "Validation failed",
                Instance = context.HttpContext.Request.Path,
            };

            var first = problem.Errors.FirstOrDefault(e => e.Value.Length > 0);
            problem.Detail = first.Key is null
                ? "The request is not valid."
                : string.IsNullOrEmpty(first.Key) ? first.Value[0] : $"{first.Key}: {first.Value[0]}";
            problem.Extensions["code"] = "VALIDATION";

            return new BadRequestObjectResult(problem)
            {
                ContentTypes = { "application/problem+json" },
            };
        };
    });

builder.Services.AddProblemDetails();
builder.Services.AddHealthChecks();

builder.Services.AddOpenApi(options =>
{
    options.AddDocumentTransformer<BearerSecuritySchemeTransformer>();
    options.AddOperationTransformer<BearerSecuritySchemeTransformer>();
});

builder.Services.AddJwtAuthentication(builder.Configuration);
builder.Services.AddAuthRateLimiting(builder.Configuration);

var allowedOrigins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? [];
builder.Services.AddCors(options =>
{
    options.AddPolicy("Frontend", policy =>
    {
        if (allowedOrigins.Length > 0)
        {
            policy.WithOrigins(allowedOrigins)
                  .AllowAnyHeader()
                  .AllowAnyMethod();
        }
    });
});

var app = builder.Build();

// ----- Database: create if missing, apply schema, seed the first admin -----
using (var scope = app.Services.CreateScope())
{
    await scope.ServiceProvider.GetRequiredService<IDatabaseInitializer>().InitializeAsync();
    // Order matters: the permission catalog must exist before the seeder assigns roles.
    await scope.ServiceProvider.GetRequiredService<ISecurityBootstrapper>().SyncPermissionCatalogAsync();
    await scope.ServiceProvider.GetRequiredService<IDataSeeder>().SeedAsync();
}

// ----- Pipeline -----
app.UseExceptionHandler();      // unhandled exceptions -> RFC 9457 problem details, no stack traces leak
app.UseStatusCodePages();

if (!app.Environment.IsDevelopment())
{
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseSecurityHeaders();

app.UseCors("Frontend");        // the React app (Inventory_Shipment.Web) runs on its own origin
app.UseRateLimiter();
app.UseAuthentication();
app.UseAuthorization();

if (app.Environment.IsDevelopment())
{
    // API reference UI at /scalar (development only) - this is what F5 opens.
    app.MapOpenApi().AllowAnonymous();
    app.MapScalarApiReference(options =>
    {
        options.WithTitle("Inventory Shipment API")
               .WithTheme(ScalarTheme.Purple)
               .AddHttpAuthentication(BearerSecuritySchemeTransformer.SchemeName, scheme => scheme.Token = string.Empty)
               .AddPreferredSecuritySchemes([BearerSecuritySchemeTransformer.SchemeName]);
    }).AllowAnonymous();
}

app.MapHealthChecks("/health").AllowAnonymous();
app.MapControllers();

// Anything else at the root goes to the API reference in Development (there is no web UI in this project).
if (app.Environment.IsDevelopment())
{
    app.MapGet("/", () => Results.Redirect("/scalar/")).AllowAnonymous();
}

app.Run();
