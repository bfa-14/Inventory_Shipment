using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Inventory.Transfers;

namespace Inventory_Shipment.Repository.Implementations;

/// <summary>
/// (91) FILL TO MAX, ADD ITEMS BELOW MIN AND A TRANSFER ORDER FROM STOCK LEVELS over script 91's procedures. The whole
/// rule is inventory.fn_TransferFill_Plan's (per item: Need from To's level and Projected, rounded up to the line's unit,
/// capped at what From has available); the procedures check the order's state with fn_TransferOrder_Blocks (actions
/// FillToMax / AddBelowMin) and build the result sentence. This part only shapes the table types and reads the sets.
/// </summary>
public sealed partial class TransferOrderRepository
{
    /* Matched by TYPE NAME on the server. FROZEN in script 91 (3.3.2). */
    private const string FillItemTypeName = "inventory.tvp_TransferFillItem";

    /// <summary>Result set 1 of usp_TransferOrder_FillToMax: what the plan did, counted.</summary>
    private sealed class FillSummaryRow
    {
        public string? Mode { get; init; }
        public bool Applied { get; init; }
        public string? Message { get; init; }
        public int Filled { get; init; }
        public int Capped { get; init; }
        public int Changed { get; init; }
        public int AtOrAboveMin { get; init; }
        public int NoLevel { get; init; }
        public int Covered { get; init; }
        public int Inactive { get; init; }
        public int OnOrder { get; init; }
        public int NotFilled { get; init; }
    }

    /// <summary>Result set 2: one row of the plan (fn_TransferFill_Plan's columns and the procedure's own), as named in SQL.</summary>
    private sealed class FillPlanRow
    {
        public int ItemId { get; init; }
        public string? ItemCode { get; init; }
        public string? ItemName { get; init; }
        public bool ItemIsActive { get; init; }
        public int ItemUnitId { get; init; }
        public string? UnitName { get; init; }
        public int PackingFormula { get; init; }
        public int? LineId { get; init; }
        public int? LineNumber { get; init; }
        public int? CurrentQuantity { get; init; }
        public int? CurrentQuantityBase { get; init; }
        public int OtherLinesBase { get; init; }
        public bool OnOrder { get; init; }
        public int ToOnHandBase { get; init; }
        public int ToInOnTheWayBase { get; init; }
        public int ToInToDispatchBase { get; init; }
        public int ToOutToDispatchBase { get; init; }
        public int ProjectedBeforeBase { get; init; }
        public int ProjectedAfterBase { get; init; }
        public bool ToHasLevel { get; init; }
        public int? MinBase { get; init; }
        public int? MaxBase { get; init; }
        public int FromOnHandBase { get; init; }
        public int FromCommittedBase { get; init; }
        public int AvailableFromBase { get; init; }
        public int AvailableForLineBase { get; init; }
        public int? NeedBase { get; init; }
        public int? UnitsNeeded { get; init; }
        public int? UnitsAvailable { get; init; }
        public string? Outcome { get; init; }
        public int? NewQuantity { get; init; }
        public int? NewQuantityBase { get; init; }
        public bool IsCapped { get; init; }
        public bool IsChanged { get; init; }
        public bool FromHasLevel { get; init; }
        public int? FromMinBase { get; init; }
        public int FromProjectedBeforeBase { get; init; }
        public int FromAfterBase { get; init; }
        public bool FromBelowMinAfter { get; init; }
        public int? PurchasesToComeBase { get; init; }
    }

    public async Task<TransferFillResult> FillToMaxAsync(
        int id, byte[]? rowVersion, IReadOnlyList<TransferFillItemRequest> addItems, bool apply, int userId,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@AddItems", ToFillItemTable(addItems).AsTableValuedParameter(FillItemTypeName));
        parameters.Add("@Apply", apply, DbType.Boolean);
        parameters.Add("@UserId", userId, DbType.Int32);

        // The apply is one transaction (the order locked, then the lines written): a deadlock victim is run again whole.
        return await QueryMultipleAsync("inventory.usp_TransferOrder_FillToMax", parameters, null, async multi =>
        {
            var summary = await multi.ReadSingleOrDefaultAsync<FillSummaryRow>() ?? new FillSummaryRow();
            List<TransferFillLineDto> lines = multi.IsConsumed ? [] : (await multi.ReadAsync<FillPlanRow>()).Select(ToDto).ToList();
            // The warnings, one sentence a row: the first column, whatever its name.
            List<string> warnings = multi.IsConsumed
                ? []
                : (await multi.ReadAsync<string?>()).Where(w => !string.IsNullOrWhiteSpace(w)).Select(w => w!).ToList();

            return new TransferFillResult
            {
                Applied = summary.Applied,
                Mode = string.IsNullOrEmpty(summary.Mode) ? (addItems.Count > 0 ? TransferFillModes.Add : TransferFillModes.Fill) : summary.Mode,
                Message = summary.Message ?? string.Empty,
                Counts = new TransferFillCountsDto
                {
                    Filled = summary.Filled,
                    Capped = summary.Capped,
                    Changed = summary.Changed,
                    AtOrAboveMin = summary.AtOrAboveMin,
                    NoLevel = summary.NoLevel,
                    Covered = summary.Covered,
                    Inactive = summary.Inactive,
                    OnOrder = summary.OnOrder,
                    NotFilled = summary.NotFilled,
                },
                Lines = lines,
                Warnings = warnings,
            };
        }, cancellationToken);
    }

    /// <summary>Result set 1 of usp_TransferOrder_BelowMinCandidates: one item with a level at To, as named in SQL.</summary>
    private sealed class BelowMinItemRow
    {
        public int ItemId { get; init; }
        public string? ItemCode { get; init; }
        public string? ItemName { get; init; }
        public string? FamilyName { get; init; }
        public string? BrandName { get; init; }
        public int BaseUnitId { get; init; }
        public string? BaseUnitName { get; init; }
        public int ToOnHandBase { get; init; }
        public int ToInOnTheWayBase { get; init; }
        public int ToInToDispatchBase { get; init; }
        public int ToOutToDispatchBase { get; init; }
        public int ProjectedBeforeBase { get; init; }
        public int? MinBase { get; init; }
        public int? MaxBase { get; init; }
        public int? NeedBase { get; init; }
        public int AvailableFromBase { get; init; }
        public bool IsBelowMin { get; init; }
        public bool OnOrder { get; init; }
        public bool FromHasLevel { get; init; }
        public int? FromMinBase { get; init; }
        public int FromProjectedBeforeBase { get; init; }
    }

    public async Task<TransferBelowMinResult> BelowMinAsync(
        int id, TransferBelowMinQuery query, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@Search", Trimmed(query.Search), DbType.String, size: 100);
        parameters.Add("@ItemFamilyId", query.ItemFamilyId, DbType.Int32);
        parameters.Add("@BrandId", query.BrandId, DbType.Int32);
        parameters.Add("@OnlyBelowMin", query.OnlyBelowMin, DbType.Boolean);
        parameters.Add("@UserId", userId, DbType.Int32);

        return await QueryMultipleAsync("inventory.usp_TransferOrder_BelowMinCandidates", parameters, null, async multi =>
        {
            var items = (await multi.ReadAsync<BelowMinItemRow>()).Select(r => new TransferBelowMinItemDto
            {
                ItemId = r.ItemId,
                ItemCode = r.ItemCode ?? string.Empty,
                ItemName = r.ItemName ?? string.Empty,
                FamilyName = r.FamilyName,
                BrandName = r.BrandName,
                BaseUnitId = r.BaseUnitId,
                BaseUnitName = r.BaseUnitName ?? string.Empty,
                ToOnHandBase = r.ToOnHandBase,
                ToInOnTheWayBase = r.ToInOnTheWayBase,
                ToInToDispatchBase = r.ToInToDispatchBase,
                ToOutToDispatchBase = r.ToOutToDispatchBase,
                ToProjectedBeforeBase = r.ProjectedBeforeBase,
                ToMinBase = r.MinBase,
                ToMaxBase = r.MaxBase,
                NeedBase = r.NeedBase,
                AvailableFromBase = r.AvailableFromBase,
                IsBelowMin = r.IsBelowMin,
                OnOrder = r.OnOrder,
                FromHasLevel = r.FromHasLevel,
                FromMinBase = r.FromMinBase,
                FromProjectedBeforeBase = r.FromProjectedBeforeBase,
            }).ToList();
            List<TransferBelowMinUnitDto> units = multi.IsConsumed ? [] : (await multi.ReadAsync<TransferBelowMinUnitDto>()).AsList();
            return new TransferBelowMinResult { Items = items, Units = units };
        }, cancellationToken);
    }

    /// <summary>The procedure's answer: the new order, its number (null when TRO numbers at release) and the sentence.</summary>
    private sealed class CreatedFromLevelsRow
    {
        public int NewId { get; init; }
        public string? DocumentNumber { get; init; }
        public string? Message { get; init; }
    }

    public async Task<CreateTransferFromLevelsResult> CreateFromLevelsAsync(
        CreateTransferFromLevelsRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@FromWarehouseId", request.FromWarehouseId, DbType.Int32);
        parameters.Add("@ToWarehouseId", request.ToWarehouseId, DbType.Int32);
        // A table, not "IN @Ids": one parameter per id would stop at SQL Server's 2,100 (the ids are made distinct there).
        parameters.Add("@ItemIds", MovementRepository.ToIdTable(request.ItemIds ?? []).AsTableValuedParameter(IdListTypeName));
        parameters.Add("@DocumentDate", ToDate(request.DocumentDate), DbType.Date);
        parameters.Add("@ExpectedArrival", ToDate(request.ExpectedArrival), DbType.Date);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        // One transaction (Save's own); a deadlock victim wrote nothing, its number sequence included, so it is run again.
        var (answer, warnings) = await QueryMultipleAsync("inventory.usp_TransferOrder_CreateFromLevels", parameters, null, async multi =>
        {
            // The answer is the procedure's draft row (NewId, DocumentNumber, Message), then its warnings (Message only).
            // Anything an inner call may have answered before the draft row is skipped.
            var sets = new List<List<CreatedFromLevelsRow>>();
            while (!multi.IsConsumed)
            {
                sets.Add((await multi.ReadAsync<CreatedFromLevelsRow>()).AsList());
            }

            var main = sets.FindLastIndex(set => set.Any(r => r.NewId > 0));
            var row = main >= 0 ? sets[main].First(r => r.NewId > 0) : null;
            var notes = main >= 0
                ? sets.Skip(main + 1).SelectMany(set => set).Select(r => r.Message).OfType<string>()
                      .Where(m => m.Length > 0).ToList()
                : [];
            return (row, (IReadOnlyList<string>)notes);
        }, cancellationToken);

        var newId = answer?.NewId is > 0 ? answer.NewId : parameters.Get<int?>("@NewId") ?? 0;
        return new CreateTransferFromLevelsResult
        {
            OrderId = newId,
            DocumentNumber = string.IsNullOrWhiteSpace(answer?.DocumentNumber) ? null : answer.DocumentNumber,
            Message = answer?.Message ?? string.Empty,
            Warnings = warnings,
        };
    }

    /// <summary>inventory.tvp_TransferFillItem (ItemId, ItemUnitId), in the type's order; ItemId is its key.</summary>
    private static DataTable ToFillItemTable(IReadOnlyList<TransferFillItemRequest> items)
    {
        var table = new DataTable();
        table.Columns.Add("ItemId", typeof(int));
        table.Columns.Add("ItemUnitId", typeof(int));

        // An empty row of the request (null) is refused by the service first; never a NullReferenceException here (90's Sec1).
        foreach (var item in (items ?? []).Where(i => i is not null))
        {
            table.Rows.Add(item.ItemId, (object?)item.ItemUnitId ?? DBNull.Value);
        }

        return table;
    }

    private static TransferFillLineDto ToDto(FillPlanRow r) => new()
    {
        ItemId = r.ItemId,
        ItemCode = r.ItemCode ?? string.Empty,
        ItemName = r.ItemName ?? string.Empty,
        ItemIsActive = r.ItemIsActive,
        LineId = r.LineId,
        LineNumber = r.LineNumber,
        ItemUnitId = r.ItemUnitId,
        UnitName = r.UnitName ?? string.Empty,
        PackingFormula = r.PackingFormula,
        CurrentQuantity = r.CurrentQuantity,
        CurrentQuantityBase = r.CurrentQuantityBase,
        NewQuantity = r.NewQuantity,
        NewQuantityBase = r.NewQuantityBase,
        OtherLinesBase = r.OtherLinesBase,
        OnOrder = r.OnOrder,
        ToOnHandBase = r.ToOnHandBase,
        ToInOnTheWayBase = r.ToInOnTheWayBase,
        ToInToDispatchBase = r.ToInToDispatchBase,
        ToOutToDispatchBase = r.ToOutToDispatchBase,
        ToProjectedBeforeBase = r.ProjectedBeforeBase,
        ToProjectedAfterBase = r.ProjectedAfterBase,
        ToHasLevel = r.ToHasLevel,
        ToMinBase = r.MinBase,
        ToMaxBase = r.MaxBase,
        NeedBase = r.NeedBase,
        UnitsNeeded = r.UnitsNeeded,
        UnitsAvailable = r.UnitsAvailable,
        FromOnHandBase = r.FromOnHandBase,
        FromCommittedBase = r.FromCommittedBase,
        AvailableFromBase = r.AvailableFromBase,
        AvailableForLineBase = r.AvailableForLineBase,
        Outcome = r.Outcome ?? string.Empty,
        IsCapped = r.IsCapped,
        IsChanged = r.IsChanged,
        FromHasLevel = r.FromHasLevel,
        FromMinBase = r.FromMinBase,
        FromProjectedBeforeBase = r.FromProjectedBeforeBase,
        FromAfterBase = r.FromAfterBase,
        FromBelowMinAfter = r.FromBelowMinAfter,
        PurchasesToComeBase = r.PurchasesToComeBase,
    };
}
