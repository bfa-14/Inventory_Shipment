namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>
/// Body of PUT {id}/status. Deactivating cascades to the whole subtree; activating touches only the
/// family itself and fails with PARENT_INACTIVE when its parent is inactive.
/// </summary>
public sealed class SetItemFamilyStatusRequest
{
    public bool IsActive { get; init; }
}
