using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Inventory_Shipment.Service.Seeding;

/// <summary>
/// Creates the first administrator account when the Users table is empty and makes sure the system
/// never ends up with no administrator. The password comes from configuration (Seed:AdminPassword)
/// and is never logged.
/// </summary>
public sealed class AdminSeeder : IDataSeeder
{
    private readonly IUserRepository _users;
    private readonly IRoleRepository _roles;
    private readonly IPasswordHasher _passwordHasher;
    private readonly IPasswordPolicy _passwordPolicy;
    private readonly SeedOptions _options;
    private readonly ILogger<AdminSeeder> _logger;

    public AdminSeeder(
        IUserRepository users,
        IRoleRepository roles,
        IPasswordHasher passwordHasher,
        IPasswordPolicy passwordPolicy,
        IOptions<SeedOptions> options,
        ILogger<AdminSeeder> logger)
    {
        _users = users;
        _roles = roles;
        _passwordHasher = passwordHasher;
        _passwordPolicy = passwordPolicy;
        _options = options.Value;
        _logger = logger;
    }

    public async Task SeedAsync(CancellationToken cancellationToken = default)
    {
        if (!_options.Enabled)
        {
            return;
        }

        if (await _users.CountAsync(cancellationToken) > 0)
        {
            await EnsureAnAdministratorExistsAsync(cancellationToken);
            return;
        }

        if (string.IsNullOrWhiteSpace(_options.AdminPassword))
        {
            _logger.LogError(
                "The Users table is empty and Seed:AdminPassword is not configured, so no administrator was created. " +
                "Set it (dotnet user-secrets set \"Seed:AdminPassword\" \"...\" or the Seed__AdminPassword environment variable) and restart.");
            return;
        }

        var errors = _passwordPolicy.Validate(_options.AdminPassword);
        if (errors.Count > 0)
        {
            _logger.LogError("Seed:AdminPassword does not meet the password policy: {Errors}", string.Join(" ", errors));
            return;
        }

        var admin = new User
        {
            Username = _options.AdminUsername.Trim(),
            Email = _options.AdminEmail.Trim(),
            FullName = _options.AdminFullName.Trim(),
            PasswordHash = _passwordHasher.Hash(_options.AdminPassword),
            IsActive = true
        };

        await _users.CreateAsync(admin, cancellationToken);

        var adminRole = await _roles.GetByNameAsync(Roles.Admin, cancellationToken);
        if (adminRole is null)
        {
            _logger.LogError(
                "Seeded administrator '{Username}' but the '{Role}' role does not exist, so no role was assigned. " +
                "Check that the security schema was applied.", admin.Username, Roles.Admin);
        }
        else
        {
            await _users.SetRolesAsync(admin.Id, [adminRole.Id], null, cancellationToken);
        }

        _logger.LogWarning("Seeded the initial administrator account '{Username}'. Change its password after the first sign-in.",
            admin.Username);
    }

    /// <summary>
    /// Recovery path for databases that predate the security module: users exist but nobody holds a
    /// system role, which would leave the security screens unreachable.
    /// </summary>
    private async Task EnsureAnAdministratorExistsAsync(CancellationToken cancellationToken)
    {
        if (await _users.CountActiveSystemAdminsAsync(null, cancellationToken) > 0)
        {
            return;
        }

        var adminRole = await _roles.GetByNameAsync(Roles.Admin, cancellationToken);
        if (adminRole is null)
        {
            _logger.LogError("No user holds a system role and the '{Role}' role does not exist.", Roles.Admin);
            return;
        }

        var username = _options.AdminUsername.Trim();
        var candidate = await _users.GetByUsernameOrEmailAsync(username, cancellationToken);
        if (candidate is null)
        {
            _logger.LogError(
                "No user holds the '{Role}' role and there is no user named '{Username}' to promote. " +
                "Assign the role manually in the database.", Roles.Admin, username);
            return;
        }

        await _users.SetRolesAsync(candidate.Id, [adminRole.Id], null, cancellationToken);
        _logger.LogWarning("No user held the '{Role}' role; granted it to '{Username}'.", Roles.Admin, candidate.Username);
    }
}
