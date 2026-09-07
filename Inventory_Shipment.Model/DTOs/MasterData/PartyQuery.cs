using System.ComponentModel.DataAnnotations;
using Inventory_Shipment.Model.Enums;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Filters, sorting and paging for the parties list (bound from the query string).</summary>
public sealed class PartyQuery
{
    /// <summary>Matches Party Code, Party Name, Phone, Mobile or E-mail (contains).</summary>
    public string? Search { get; init; }

    /// <summary>Keeps only the parties carrying that type. Null = every party, whatever its types.</summary>
    public PartyType? PartyType { get; init; }

    /// <summary>Null = parties of every branch, including those without one.</summary>
    public int? BranchId { get; init; }

    /// <summary>Null = both active and inactive parties.</summary>
    public bool? IsActive { get; init; }

    /// <summary>PartyCode | PartyName | BranchName | Email | Phone | IsActive | CreatedAtUtc.</summary>
    public string SortBy { get; init; } = "PartyCode";

    /// <summary>asc | desc.</summary>
    public string SortDir { get; init; } = "asc";

    [Range(1, int.MaxValue)]
    public int Page { get; init; } = 1;

    [Range(1, 200)]
    public int PageSize { get; init; } = 10;
}
