namespace Inventory_Shipment.Model.DTOs.Users;

/// <summary>
/// A user as it appears in a dropdown - the smallest projection of security.Users. Any signed-in user
/// may read it (the Parties form links a party to the user it signs in as), so it deliberately carries
/// nothing sensitive: no e-mail, no roles, no sign-in history.
/// </summary>
public sealed class UserLookupDto
{
    public int Id { get; init; }
    public string Username { get; init; } = string.Empty;
    public string FullName { get; init; } = string.Empty;
    public bool IsActive { get; init; }
}
