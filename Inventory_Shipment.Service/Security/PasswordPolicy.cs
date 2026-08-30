using Inventory_Shipment.Model.Options;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Options;

namespace Inventory_Shipment.Service.Security;

public sealed class PasswordPolicy : IPasswordPolicy
{
    private const int MaxLength = 128;

    private readonly PasswordPolicyOptions _options;

    public PasswordPolicy(IOptions<SecurityOptions> options)
    {
        _options = options.Value.PasswordPolicy;
    }

    public IReadOnlyList<string> Validate(string? password)
    {
        var errors = new List<string>();

        if (string.IsNullOrEmpty(password))
        {
            errors.Add("Password is required.");
            return errors;
        }

        if (password.Length < _options.MinLength)
        {
            errors.Add($"Password must be at least {_options.MinLength} characters long.");
        }

        if (password.Length > MaxLength)
        {
            errors.Add($"Password must be at most {MaxLength} characters long.");
        }

        if (_options.RequireUppercase && !password.Any(char.IsUpper))
        {
            errors.Add("Password must contain at least one uppercase letter.");
        }

        if (_options.RequireLowercase && !password.Any(char.IsLower))
        {
            errors.Add("Password must contain at least one lowercase letter.");
        }

        if (_options.RequireDigit && !password.Any(char.IsDigit))
        {
            errors.Add("Password must contain at least one digit.");
        }

        if (_options.RequireNonAlphanumeric && password.All(char.IsLetterOrDigit))
        {
            errors.Add("Password must contain at least one symbol (for example ! @ # $ %).");
        }

        return errors;
    }
}
