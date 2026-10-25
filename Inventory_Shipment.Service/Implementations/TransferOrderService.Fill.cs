using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory.Transfers;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Repository.Exceptions;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// (91) FILL TO MAX, ADD ITEMS BELOW MIN, AND A TRANSFER ORDER FROM STOCK LEVELS (script 91, FB decisions 20 and 24).
/// <list type="bullet">
///   <item>THE RULE IS THE DATABASE'S (inventory.fn_TransferFill_Plan, 3.4.3): per item, To is topped up to its Max (else
///   its Min) from what From has available, rounded up to the line's unit; the item's first line is SET, never added to;
///   a second run changes nothing. The refusals are the first row of fn_TransferOrder_Blocks for FillToMax / AddBelowMin,
///   in its words (a saved draft only, To with levels...), with the codes of every transfer action.</item>
///   <item>PREVIEW, THEN APPLY: the preview writes nothing and takes no lock; the apply sends the ORDER's row version and
///   the procedure computes the plan again inside its transaction, so what is written is never a stale preview.</item>
///   <item>THE PERMISSION IS inventory.transfers.create (FB decision 20); creating an order from Stock Levels needs
///   inventory.stocklevels.view too (L15): nobody gains a power they lack.</item>
/// </list>
/// </summary>
public sealed partial class TransferOrderService
{
    private const string MissingRowVersionMessage = "The row version is missing. Reload the page and try again.";

    public Task<Result<TransferFillResult>> FillToMaxPreviewAsync(
        int id, TransferFillRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => FillAsync(id, request, apply: false, userId, permissions, cancellationToken);

    public Task<Result<TransferFillResult>> FillToMaxAsync(
        int id, TransferFillRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
        => FillAsync(id, request, apply: true, userId, permissions, cancellationToken);

    private async Task<Result<TransferFillResult>> FillAsync(
        int id, TransferFillRequest request, bool apply, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersCreate))
        {
            return Forbidden<TransferFillResult>(Permissions.Inventory.TransfersCreate);
        }

        var addItems = request.AddItems ?? [];

        // 90's guard first (Sec1, Sec4): a row version that cannot be one (the apply's; a preview takes none) and an empty
        // row of addItems ("addItems": [null] would end in a NullReferenceException and a 500) are 400 VALIDATION.
        if (BadRequest<TransferFillResult>(apply ? request.RowVersion : null, addItems) is { } bad)
        {
            return bad;
        }

        // The apply is made with the order's row version (L9): without one it would overwrite, unseen, a change another
        // user saved since the preview. The page always sends it; the procedure refuses it too (62000).
        if (apply && string.IsNullOrWhiteSpace(request.RowVersion))
        {
            return Result<TransferFillResult>.Failure(ErrorType.Validation, MissingRowVersionMessage, "VALIDATION");
        }

        // The table type's key is the item: an item ticked twice could never be one row.
        if (addItems.GroupBy(i => i.ItemId).Any(g => g.Count() > 1))
        {
            return Result<TransferFillResult>.Failure(ErrorType.Validation, "Each item once.", "VALIDATION");
        }

        var rowVersion = apply ? ToRowVersion(request.RowVersion) : null;

        TransferFillResult plan;
        try
        {
            plan = await _transfers.FillToMaxAsync(id, rowVersion, addItems, apply, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferFillResult>(ex);
        }

        if (!apply)
        {
            return Result<TransferFillResult>.Success(plan);
        }

        _logger.LogInformation("Transfer order {TransferOrderId}: {Mode} applied by user {UserId}, {Changed} line(s) changed",
            id, plan.Mode, userId, plan.Counts.Changed);

        // The answer carries the order as it now stands, as every transfer action does: the page never patches its copy.
        // Read after the commit (AfterCommit, 90's Sec5): a caller gone meanwhile never turns an applied fill into a 499.
        var read = await ReadAsync(id, userId, permissions, AfterCommit);
        if (read.IsFailure || read.Value is null)
        {
            return Result<TransferFillResult>.Failure(read.ErrorType, read.Error ?? NotFoundMessage, read.Code ?? "NOT_FOUND");
        }

        return Result<TransferFillResult>.Success(new TransferFillResult
        {
            Applied = plan.Applied,
            Mode = plan.Mode,
            Message = plan.Message,
            Counts = plan.Counts,
            Lines = plan.Lines,
            Warnings = plan.Warnings,
            Order = read.Value,
        });
    }

    public async Task<Result<TransferBelowMinResult>> BelowMinAsync(
        int id, TransferBelowMinQuery query, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersCreate))
        {
            return Forbidden<TransferBelowMinResult>(Permissions.Inventory.TransfersCreate);
        }

        try
        {
            return Result<TransferBelowMinResult>.Success(await _transfers.BelowMinAsync(id, query, userId, cancellationToken));
        }
        catch (BusinessRuleException ex)
        {
            return Failure<TransferBelowMinResult>(ex);
        }
    }

    public async Task<Result<CreateTransferFromLevelsResult>> CreateFromLevelsAsync(
        CreateTransferFromLevelsRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default)
    {
        if (!permissions.Contains(Permissions.Inventory.TransfersCreate))
        {
            return Forbidden<CreateTransferFromLevelsResult>(Permissions.Inventory.TransfersCreate);
        }

        if (!permissions.Contains(Permissions.Inventory.StockLevelsView))
        {
            return Forbidden<CreateTransferFromLevelsResult>(Permissions.Inventory.StockLevelsView);
        }

        CreateTransferFromLevelsResult created;
        try
        {
            // The warehouses, "Tick at least one item." and "Nothing to transfer: …" are the procedure's (62000 / 62009).
            // One short command whose answer is read after its draft is saved: not cancelled with the request, so a caller
            // gone meanwhile never turns a draft that was made into a 499 (and a second click into a second draft).
            created = await _transfers.CreateFromLevelsAsync(request, userId, AfterCommit);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<CreateTransferFromLevelsResult>(ex);
        }

        _logger.LogInformation("Transfer order {TransferOrderId} created from Stock Levels by user {UserId}: {Items} item(s) ticked",
            created.OrderId, userId, request.ItemIds?.Count ?? 0);
        return Result<CreateTransferFromLevelsResult>.Success(created);
    }
}
