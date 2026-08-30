namespace Inventory_Shipment.Model.Entities;

/// <summary>
/// A permission (table security.Permissions). Rows are owned by the application catalog
/// (see <see cref="Security.Permissions"/>) and synced on start-up.
/// </summary>
public class Permission
{
    public int Id { get; set; }
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Module { get; set; } = string.Empty;
    public string? Description { get; set; }
    public int SortOrder { get; set; }
}
