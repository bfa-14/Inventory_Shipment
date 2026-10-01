namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Encrypts a secret before it is stored (the SMTP password) and decrypts it when it is needed.
/// The host implements it with ASP.NET Core Data Protection; the keys never leave the server.
/// </summary>
public interface ISecretProtector
{
    string Protect(string plainText);

    /// <summary>False when the value can no longer be decrypted (the keys that protected it are gone).</summary>
    bool TryUnprotect(string protectedText, out string plainText);
}
