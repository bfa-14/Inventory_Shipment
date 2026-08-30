namespace Inventory_Shipment.Model.Security;

/// <summary>
/// Well-known role names. Roles live in security.Roles and are assigned to users through security.UserRoles;
/// these constants only name the ones the application itself relies on.
/// </summary>
public static class Roles
{
    /// <summary>The system role. It always holds every permission and cannot be renamed or deleted.</summary>
    public const string Admin = "Admin";

    public const string Manager = "Manager";
    public const string User = "User";
}
