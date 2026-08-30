using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Filters, sorting and paging for the branches list (bound from the query string).</summary>
public sealed class BranchQuery
{
    /// <summary>Matches Branch Code or Branch Name (contains).</summary>
    public string? Search { get; init; }

    /// <summary>Null = both active and inactive branches.</summary>
    public bool? IsActive { get; init; }

    /// <summary>Null = main and non-main branches.</summary>
    public bool? IsMainBranch { get; init; }

    /// <summary>BranchCode | BranchName | Address | IsMainBranch | IsActive | CreatedAtUtc.</summary>
    public string SortBy { get; init; } = "BranchCode";

    /// <summary>asc | desc.</summary>
    public string SortDir { get; init; } = "asc";

    [Range(1, int.MaxValue)]
    public int Page { get; init; } = 1;

    [Range(1, 200)]
    public int PageSize { get; init; } = 10;
}
