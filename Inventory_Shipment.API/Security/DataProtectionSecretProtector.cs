using System.Security.Cryptography;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.DataProtection;

namespace Inventory_Shipment.API.Security;

/// <summary>
/// The SMTP password encrypted with ASP.NET Core Data Protection, purpose "EmailSettings.SmtpPassword.v1".
/// The keys are in DataProtection:KeysPath (default App_Data/keys): a copy of the database without them
/// cannot read the password - which is the point, and why losing them only means typing it again.
/// </summary>
public sealed class DataProtectionSecretProtector : ISecretProtector
{
    public const string Purpose = "EmailSettings.SmtpPassword.v1";

    private readonly IDataProtector _protector;

    public DataProtectionSecretProtector(IDataProtectionProvider provider)
    {
        _protector = provider.CreateProtector(Purpose);
    }

    public string Protect(string plainText) => _protector.Protect(plainText);

    public bool TryUnprotect(string protectedText, out string plainText)
    {
        try
        {
            plainText = _protector.Unprotect(protectedText);
            return true;
        }
        catch (CryptographicException)
        {
            plainText = string.Empty;
            return false;
        }
        catch (FormatException)
        {
            plainText = string.Empty;
            return false;
        }
    }
}
