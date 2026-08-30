using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;

namespace Inventory_Shipment.Service.Mapping;

public static class BranchMapper
{
    public static BranchDto ToDto(this Branch branch) => new()
    {
        Id = branch.Id,
        BranchCode = branch.BranchCode,
        BranchName = branch.BranchName,
        Address = branch.Address,
        IsMainBranch = branch.IsMainBranch,
        IsActive = branch.IsActive,
        CreatedAtUtc = branch.CreatedAtUtc.AsUtc(),
        UpdatedAtUtc = branch.UpdatedAtUtc.AsUtc(),
        RowVersion = Convert.ToBase64String(branch.RowVersion)
    };
}
