using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Inventory.Transfers;
using Inventory_Shipment.Model.Security;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Inventory;

/// <summary>
/// (93) BATCH, SERIAL AND EXPIRY ON TRANSFERS. The rows themselves travel on 90's routes (lines[].tracking on dispatch,
/// receive and dispatch-and-receive); these three read: the dialog's Check (Dispatch Transfers), a posting's rows with
/// their state (View Transfer Orders), and the serials known at the order's From (Dispatch Transfers). No new
/// permission (B11). The refusals are the procedures' sentences: 62016 → 400 TRANSFER_TRACKING, 62017 → 409
/// SERIAL_ON_THE_WAY, 62006 → 404.
/// </summary>
public sealed partial class TransferOrdersController
{
    /// <summary>
    /// The dialog's Done: the whole dispatch as it would be posted (DispatchTransferRequest; date and ETA ignored) and,
    /// with forLineId, only that line's warnings. Always 200 with the problems - errors (Severity Error: the posting
    /// would refuse them, with the same sentences) and warnings - empty when all is good. Nothing is written.
    /// </summary>
    [HttpPost("{id:int}/dispatch/check-tracking")]
    [HasPermission(Permissions.Inventory.TransfersDispatch)]
    [ProducesResponseType<CheckDispatchTrackingResult>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<CheckDispatchTrackingResult>> CheckDispatchTracking(
        int id, [FromBody] DispatchTransferRequest request, [FromQuery] int? forLineId, CancellationToken cancellationToken)
    {
        var result = await _transfers.CheckDispatchTrackingAsync(id, request, forLineId, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// The serial nos., batches or expiry dates of one dispatch or receipt, by line and row, with their state ("On the
    /// way", "Received by TRR-…", "Written off by TRR-… (Missing / stolen)", "Reversed"). onTheWayOnly=true: a posted
    /// dispatch's rows still on the way (the Receive dialog). 404 when the posting is not one of the order's.
    /// </summary>
    [HttpGet("{id:int}/postings/{postingId:int}/tracking")]
    [HasPermission(Permissions.Inventory.TransfersView)]
    [ProducesResponseType<IReadOnlyList<TransferTrackingRowDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<IReadOnlyList<TransferTrackingRowDto>>> PostingTracking(
        int id, int postingId, [FromQuery] bool onTheWayOnly, CancellationToken cancellationToken)
    {
        var result = await _transfers.PostingTrackingAsync(id, postingId, onTheWayOnly, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// "Known at {From}…" for a line of a serial item: the serials received into the order's From by transfers and not
    /// sent since (at most 2,000), and the line's tracking kind now; other kinds answer no serials.
    /// </summary>
    [HttpGet("{id:int}/lines/{lineId:int}/tracking-suggestions")]
    [HasPermission(Permissions.Inventory.TransfersDispatch)]
    [ProducesResponseType<TransferTrackingSuggestionsDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<TransferTrackingSuggestionsDto>> TrackingSuggestions(
        int id, int lineId, CancellationToken cancellationToken)
    {
        var result = await _transfers.TrackingSuggestionsAsync(id, lineId, User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }
}
