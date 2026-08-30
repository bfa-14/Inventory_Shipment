using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Body of both POST (create) and PUT (update) on a branch.</summary>
public sealed class SaveBranchRequest
{
    [Required]
    [StringLength(20, MinimumLength = 1)]
    public string BranchCode { get; init; } = string.Empty;

    [Required]
    [StringLength(150, MinimumLength = 1)]
    public string BranchName { get; init; } = string.Empty;

    [StringLength(500)]
    public string? Address { get; init; }

    public bool IsMainBranch { get; init; }

    public bool IsActive { get; init; } = true;

    /// <summary>
    /// Set to true to confirm taking the Main Branch flag away from the branch that holds it.
    /// Without it the request fails with MAIN_BRANCH_EXISTS so the user can be asked first.
    /// </summary>
    public bool ReplaceMainBranch { get; init; }

    /// <summary>Base64 ROWVERSION read with the branch (update only). Null skips the concurrency check.</summary>
    public string? RowVersion { get; init; }
}
