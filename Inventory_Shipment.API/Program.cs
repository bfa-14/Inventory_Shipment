using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.API.Middleware;
using Inventory_Shipment.API.OpenApi;
using Inventory_Shipment.API.Security;
using Inventory_Shipment.API.Workers;
using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Repository;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Service;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Formatters;
using Microsoft.Extensions.Options;
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

builder.Services.AddOptions<AppOptions>()
    .Bind(builder.Configuration.GetSection(AppOptions.SectionName));

builder.Services.AddOptions<ApprovalOptions>()
    .Bind(builder.Configuration.GetSection(ApprovalOptions.SectionName));

// ----- Layers -----
var connectionString = builder.Configuration.GetConnectionString("DefaultConnection")
    ?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing from configuration.");

builder.Services.AddRepositoryLayer(options =>
{
    builder.Configuration.GetSection(DatabaseOptions.SectionName).Bind(options);
    options.ConnectionString = connectionString;
});
builder.Services.AddServiceLayer();

// ----- Secrets and email -----
// The SMTP password is stored encrypted with these keys. They live outside the database on purpose (a copy
// of the database alone cannot read it); losing them only means typing the password again in Settings > Email.
var keysPath = builder.Configuration["DataProtection:KeysPath"];
if (string.IsNullOrWhiteSpace(keysPath))
{
    keysPath = Path.Combine(builder.Environment.ContentRootPath, "App_Data", "keys");
}

Directory.CreateDirectory(keysPath);
builder.Services.AddDataProtection()
    .SetApplicationName("Inventory_Shipment")
    .PersistKeysToFileSystem(new DirectoryInfo(keysPath));
builder.Services.AddSingleton<ISecretProtector, DataProtectionSecretProtector>();
builder.Services.AddHostedService<EmailOutboxWorker>();
builder.Services.AddHostedService<ApprovalReminderWorker>();

// ----- Web -----
builder.Services.AddControllers(options =>
    {
        // NO IMPLICIT [Required] ON NON-NULLABLE REFERENCE TYPES. It is what answered every body the JSON
        // reader could not read with "The request field is required." on top of the real error. The
        // checks it made are kept elsewhere: a null for a non-nullable property is refused while
        // reading the JSON (the input formatter below), an empty or null body by the binder itself
        // ("A non-empty request body is required."), and an omitted string that must not be empty
        // carries an explicit [Required].
        options.SuppressImplicitRequiredAttributeForNonNullableReferenceTypes = true;
    })
    .AddJsonOptions(options =>
    {
        options.JsonSerializerOptions.Converters.Add(new JsonStringEnumConverter());

        // Every *Utc time as UTC with its "Z"; the calendar dates (DocumentDate, Eta...) unchanged (UtcDateTimeJson).
        options.JsonSerializerOptions.TypeInfoResolver = (options.JsonSerializerOptions.TypeInfoResolver ?? new DefaultJsonTypeInfoResolver())
            .WithAddedModifier(UtcDateTimeJson.MarkUtcProperties);
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
                Instance = JsonInputErrors.SafePath(context.HttpContext.Request.Path),
            };

            // A BODY THE JSON READER COULD NOT READ: one sentence per place ("Line 1: Expiry Date is not a
            // valid date."), shown by the pages as it is, and a warning in the log - the reader itself only
            // logs at Debug, which is how a wrong value sent by a page went unnoticed. Never the value.
            var unreadable = problem.Errors.Where(e => JsonInputErrors.IsJsonPath(e.Key) && e.Value.Length > 0).ToList();
            foreach (var (path, messages) in unreadable)
            {
                problem.Errors[path] = [JsonInputErrors.Describe(path, messages[0])];
            }

            if (unreadable.Count > 0)
            {
                var sentence = problem.Errors[unreadable[0].Key][0];
                context.HttpContext.RequestServices.GetRequiredService<ILoggerFactory>()
                    .CreateLogger("Inventory_Shipment.API.RequestBody")
                    .LogWarning("Request body refused: {Method} {Path} at {JsonPath}: {Error}",
                        context.HttpContext.Request.Method, JsonInputErrors.SafePath(context.HttpContext.Request.Path), unreadable[0].Key, sentence);
                problem.Detail = sentence;
            }
            else
            {
                var first = problem.Errors.FirstOrDefault(e => e.Value.Length > 0);
                problem.Detail = first.Key is null
                    ? "The request is not valid."
                    : string.IsNullOrEmpty(first.Key) ? first.Value[0] : $"{first.Key}: {first.Value[0]}";
            }

            problem.Extensions["code"] = "VALIDATION";

            return new BadRequestObjectResult(problem)
            {
                ContentTypes = { "application/problem+json" },
            };
        };
    });

// REQUEST BODIES REFUSE A NULL FOR A NON-NULLABLE PROPERTY ("lines": null), with the JSON path in the
// error - the check the implicit [Required] made, moved to where the value is read. On the INPUT
// formatter only: responses keep the shared options, because rows read from the database may hold a
// NULL in a property declared non-nullable and must still be written out.
builder.Services.AddOptions<MvcOptions>()
    .PostConfigure<IOptions<JsonOptions>, ILoggerFactory>((mvc, json, loggers) =>
    {
        for (var i = 0; i < mvc.InputFormatters.Count; i++)
        {
            if (mvc.InputFormatters[i] is not SystemTextJsonInputFormatter)
            {
                continue;
            }

            var shared = json.Value.JsonSerializerOptions;
            var input = new JsonOptions { AllowInputFormatterExceptionMessages = json.Value.AllowInputFormatterExceptionMessages };
            input.JsonSerializerOptions.PropertyNamingPolicy = shared.PropertyNamingPolicy;
            input.JsonSerializerOptions.PropertyNameCaseInsensitive = shared.PropertyNameCaseInsensitive;
            input.JsonSerializerOptions.NumberHandling = shared.NumberHandling;
            input.JsonSerializerOptions.TypeInfoResolver = shared.TypeInfoResolver;
            foreach (var converter in shared.Converters)
            {
                input.JsonSerializerOptions.Converters.Add(converter);
            }

            input.JsonSerializerOptions.RespectNullableAnnotations = true;
            mvc.InputFormatters[i] = new SystemTextJsonInputFormatter(input, loggers.CreateLogger<SystemTextJsonInputFormatter>());
        }
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
