using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class LandedCostAdjustmentRepository : ILandedCostAdjustmentRepository
{
    private readonly ISqlConnectionFactory _connectionFactory;

    public LandedCostAdjustmentRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    private sealed class ListRow
    {
        public int Id { get; init; }
        public string DocumentNumber { get; init; } = string.Empty;
        public DateTime DocumentDate { get; init; }
        public int BranchId { get; init; }
        public string BranchName { get; init; } = string.Empty;
        public int SourceInvoiceId { get; init; }
        public string? SourceInvoiceNumber { get; init; }
        public int SupplierId { get; init; }
        public string SupplierName { get; init; } = string.Empty;
        public byte Status { get; init; }
        public decimal TotalChargesBase { get; init; }
        public decimal InventoryPortionBase { get; init; }
        public decimal CogsPortionBase { get; init; }
        public DateTime? PostedAtUtc { get; init; }
        public string? PostedByName { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public string? CreatedByName { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public LandedCostAdjustmentListDto ToDto() => new()
        {
            Id = Id,
            DocumentNumber = DocumentNumber,
            DocumentDate = DocumentDate,
            BranchId = BranchId,
            BranchName = BranchName,
            SourceInvoiceId = SourceInvoiceId,
            SourceInvoiceNumber = SourceInvoiceNumber,
            SupplierId = SupplierId,
            SupplierName = SupplierName,
            Status = LandedCostAdjustmentStatus.From(Status),
            TotalChargesBase = TotalChargesBase,
            InventoryPortionBase = InventoryPortionBase,
            CogsPortionBase = CogsPortionBase,
            PostedAtUtc = PostedAtUtc,
            PostedByName = PostedByName,
            CreatedAtUtc = CreatedAtUtc,
            CreatedByName = CreatedByName,
            RowVersion = RowVersion,
        };
    }

    public async Task<(IReadOnlyList<LandedCostAdjustmentListDto> Items, int TotalCount)> SearchAsync(
        LandedCostAdjustmentQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.SourceInvoiceId,
            query.BranchId,
            Status = LandedCostAdjustmentStatus.ToCode(query.Status),
            DateFrom = query.DateFrom?.ToDateTime(TimeOnly.MinValue),
            DateTo = query.DateTo?.ToDateTime(TimeOnly.MinValue),
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<ListRow>(new CommandDefinition(
            "purchase.usp_LandedCostAdjustment_Search", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var list = rows.AsList();
        var total = list.Count > 0 ? list[0].TotalCount : 0;
        return (list.Select(r => r.ToDto()).ToList(), total);
    }

    private sealed class HeaderRow
    {
        public int Id { get; init; }
        public string DocumentNumber { get; init; } = string.Empty;
        public DateTime DocumentDate { get; init; }
        public int BranchId { get; init; }
        public string BranchName { get; init; } = string.Empty;
        public int SourceInvoiceId { get; init; }
        public string? SourceInvoiceNumber { get; init; }
        public int SupplierId { get; init; }
        public string SupplierCode { get; init; } = string.Empty;
        public string SupplierName { get; init; } = string.Empty;
        public int WarehouseId { get; init; }
        public string WarehouseName { get; init; } = string.Empty;
        public string? Notes { get; init; }
        public byte Status { get; init; }
        public decimal TotalChargesBase { get; init; }
        public decimal InventoryPortionBase { get; init; }
        public decimal CogsPortionBase { get; init; }
        public DateTime? PostedAtUtc { get; init; }
        public int? PostedBy { get; init; }
        public string? PostedByName { get; init; }
        public DateTime? CancelledAtUtc { get; init; }
        public string? CancelReason { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public int? CreatedBy { get; init; }
        public string? CreatedByName { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public byte[] RowVersion { get; init; } = [];
    }

    /// <summary>A split row as the procedure returns it. LineNumber here, LineNo on the DTO — LINENO is reserved in T-SQL.</summary>
    private sealed class SplitRow
    {
        public int Id { get; init; }
        public int PurchaseLineId { get; init; }
        public int LineNumber { get; init; }
        public int ItemId { get; init; }
        public string ItemCode { get; init; } = string.Empty;
        public string ItemName { get; init; } = string.Empty;
        public int WarehouseId { get; init; }
        public string WarehouseCode { get; init; } = string.Empty;
        public int ReceivedBase { get; init; }
        public int NetReceivedBase { get; init; }
        public int RemainingBase { get; init; }
        public decimal AllocatedBase { get; init; }
        public decimal ExtraPerBaseUnit { get; init; }
        public decimal InventoryPortionBase { get; init; }
        public decimal CogsPortionBase { get; init; }
        public decimal LandedCostBefore { get; init; }
        public decimal LandedCostAfter { get; init; }

        public LandedCostAdjustmentLineDto ToDto() => new()
        {
            Id = Id,
            PurchaseLineId = PurchaseLineId,
            LineNo = LineNumber,
            ItemId = ItemId,
            ItemCode = ItemCode,
            ItemName = ItemName,
            WarehouseId = WarehouseId,
            WarehouseCode = WarehouseCode,
            ReceivedBase = ReceivedBase,
            NetReceivedBase = NetReceivedBase,
            RemainingBase = RemainingBase,
            AllocatedBase = AllocatedBase,
            ExtraPerBaseUnit = ExtraPerBaseUnit,
            InventoryPortionBase = InventoryPortionBase,
            CogsPortionBase = CogsPortionBase,
            LandedCostBefore = LandedCostBefore,
            LandedCostAfter = LandedCostAfter,
        };
    }

    public async Task<LandedCostAdjustmentDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();

        // Three result sets in one round trip, so the header's totals and the split agree.
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "purchase.usp_LandedCostAdjustment_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var header = await multi.ReadSingleOrDefaultAsync<HeaderRow>();
        if (header is null)
        {
            return null;
        }

        var charges = (await multi.ReadAsync<PurchaseChargeRow>()).AsList();
        var lines = (await multi.ReadAsync<SplitRow>()).AsList();

        return new LandedCostAdjustmentDto
        {
            Id = header.Id,
            DocumentNumber = header.DocumentNumber,
            DocumentDate = header.DocumentDate,
            BranchId = header.BranchId,
            BranchName = header.BranchName,
            SourceInvoiceId = header.SourceInvoiceId,
            SourceInvoiceNumber = header.SourceInvoiceNumber,
            SupplierId = header.SupplierId,
            SupplierCode = header.SupplierCode,
            SupplierName = header.SupplierName,
            WarehouseId = header.WarehouseId,
            WarehouseName = header.WarehouseName,
            Notes = header.Notes,
            Status = LandedCostAdjustmentStatus.From(header.Status),
            TotalChargesBase = header.TotalChargesBase,
            InventoryPortionBase = header.InventoryPortionBase,
            CogsPortionBase = header.CogsPortionBase,
            PostedAtUtc = header.PostedAtUtc,
            PostedBy = header.PostedBy,
            PostedByName = header.PostedByName,
            CancelledAtUtc = header.CancelledAtUtc,
            CancelReason = header.CancelReason,
            CreatedAtUtc = header.CreatedAtUtc,
            CreatedBy = header.CreatedBy,
            CreatedByName = header.CreatedByName,
            UpdatedAtUtc = header.UpdatedAtUtc,
            RowVersion = header.RowVersion,
            // The adjustment's own charges carry no DocumentKind column of their own: they are all LCA.
            Charges = charges.Select(c => c.ToDto(ChargeDocumentKinds.Adjustment, header.Id, header.DocumentNumber)).ToList(),
            Lines = lines.Select(l => l.ToDto()).ToList(),
        };
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<int> SaveAsync(
        SaveLandedCostAdjustmentRequest request, int? id, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@SourceInvoiceId", request.SourceInvoiceId, DbType.Int32);
        parameters.Add("@DocumentDate", request.DocumentDate.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@Notes", request.Notes, DbType.String, size: 1000);
        parameters.Add("@Charges", PurchaseChargeTables.Charges(request.Charges).AsTableValuedParameter(PurchaseChargeTables.ChargeTypeName));
        parameters.Add("@ManualAllocations", PurchaseChargeTables.ManualAllocations(request.ManualAllocations, request.Charges).AsTableValuedParameter(PurchaseChargeTables.ManualAllocationTypeName));
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        try
        {
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.ExecuteAsync(new CommandDefinition(
                    "purchase.usp_LandedCostAdjustment_Save", parameters,
                    commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            }, cancellationToken);

            return parameters.Get<int>("@NewId");
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public Task PostAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_LandedCostAdjustment_Post",
            new { Id = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_LandedCostAdjustment_Cancel",
            new { Id = id, Reason = reason, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_LandedCostAdjustment_Delete", new { Id = id, UserId = userId }, cancellationToken);

    /// <summary>
    /// One procedure call, run again if SQL Server made it the deadlock victim: posting an
    /// adjustment rewrites the invoice's lines and every touched item's costs, so a reader of the
    /// same invoice arriving between the two is enough for one of them to be killed.
    /// </summary>
    private async Task ExecuteAsync(string procedure, object parameters, CancellationToken cancellationToken)
    {
        try
        {
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.ExecuteAsync(new CommandDefinition(
                    procedure, parameters, commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            }, cancellationToken);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    private static byte[]? ToRowVersion(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return Convert.TryFromBase64String(value, new byte[8], out var written) && written == 8
            ? Convert.FromBase64String(value)
            : null;
    }
}
