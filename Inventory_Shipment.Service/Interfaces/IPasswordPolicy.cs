namespace Inventory_Shipment.Service.Interfaces;

public interface IPasswordPolicy
{
    /// <summary>Returns an empty list when the password satisfies the configured policy.</summary>
    IReadOnlyList<string> Validate(string? password);
}
