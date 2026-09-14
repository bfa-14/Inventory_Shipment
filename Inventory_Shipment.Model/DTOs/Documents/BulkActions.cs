using System.ComponentModel.DataAnnotations;
using Inventory_Shipment.Model.Common;

namespace Inventory_Shipment.Model.DTOs.Documents;

/// <summary>The ids a list page selected. Every document family's bulk endpoints take this.</summary>
public sealed class BulkActionRequest
{
    [Required]
    [MinLength(1)]
    public int[] Ids { get; init; } = [];
}

/// <summary>What happened to one document of a bulk action.</summary>
public sealed class BulkActionItemResult
{
    public int Id { get; init; }

    /// <summary>The number after the action — assigned by a posting — or null for a draft / a failure.</summary>
    public string? DocumentNumber { get; init; }

    public bool Ok { get; init; }

    /// <summary>The refusal's code (NO_LINES, INSUFFICIENT_STOCK, FORBIDDEN…) when not ok.</summary>
    public string? Code { get; init; }

    /// <summary>The procedure's own sentence when not ok.</summary>
    public string? Message { get; init; }
}

/// <summary>
/// The answer to a bulk post or delete.
///
/// ONE DOCUMENT'S REFUSAL NEVER STOPS THE OTHERS, and this shape is what makes that honest: the
/// counts say how many went through, and <see cref="Results"/> says, in the order the ids were sent,
/// what happened to each — so a list page can mark three rows posted and one row "no lines" rather
/// than showing a single error for a batch that mostly worked.
/// </summary>
public sealed class BulkActionResult
{
    public int Requested { get; init; }
    public int Succeeded { get; init; }
    public int Failed { get; init; }
    public IReadOnlyList<BulkActionItemResult> Results { get; init; } = [];

    /// <summary>Builds the result from the per-document outcomes, keeping their order.</summary>
    public static BulkActionResult From(IReadOnlyList<BulkActionItemResult> results) => new()
    {
        Requested = results.Count,
        Succeeded = results.Count(r => r.Ok),
        Failed = results.Count(r => !r.Ok),
        Results = results,
    };

    /// <summary>One outcome from a service Result whose value is the document number.</summary>
    public static BulkActionItemResult Item(int id, Result<string?> outcome) => new()
    {
        Id = id,
        DocumentNumber = outcome.IsSuccess ? outcome.Value : null,
        Ok = outcome.IsSuccess,
        Code = outcome.IsSuccess ? null : outcome.Code,
        Message = outcome.IsSuccess ? null : outcome.Error,
    };
}
