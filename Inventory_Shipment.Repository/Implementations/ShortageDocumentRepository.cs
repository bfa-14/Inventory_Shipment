using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Inventory.Shortages;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class ShortageDocumentRepository : IShortageDocumentRepository
{
    /// <summary>Matched by TYPE NAME on the server; a wrong one fails with a message that never mentions the type.</summary>
    private const string LineTypeName = "inventory.tvp_ShortageLine";

    /// <summary>The columns the search procedure will sort by; anything else falls back to the document date.</summary>
    private static readonly string[] SortColumns =
        ["DocumentNumber", "DocumentDate", "Description", "WarehouseName", "SupplierName", "Status", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public ShortageDocumentRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<IReadOnlyList<ShortageLiveRowDto>> CalculateAsync(
        ShortageCalculateQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            query.WarehouseId,
            query.SupplierId,
            query.LeadTimeMonths,
            query.MonthsOfHistory,
            query.ItemFamilyId,
            query.BrandId,
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.OnlyShortages,
        };

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<ShortageLiveRowDto>(new CommandDefinition(
                "inventory.usp_Shortage_Calculate", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return rows.AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>The list row as the procedure returns it, before the status becomes a word.</summary>
    private sealed class ListRow
    {
        public int Id { get; init; }
        public string DocumentNumber { get; init; } = string.Empty;
        public string Description { get; init; } = string.Empty;
        public DateTime DocumentDate { get; init; }
        public int BranchId { get; init; }
        public string BranchName { get; init; } = string.Empty;
        public int WarehouseId { get; init; }
        public string WarehouseName { get; init; } = string.Empty;
        public int SupplierId { get; init; }
        public string SupplierCode { get; init; } = string.Empty;
        public string SupplierName { get; init; } = string.Empty;
        public decimal LeadTimeMonths { get; init; }
        public int MonthsOfHistory { get; init; }
        public byte Status { get; init; }
        public int TotalLines { get; init; }
        public int TotalShortageBase { get; init; }
        public int TotalRequiredBase { get; init; }
        public decimal TotalContainers { get; init; }
        public int ContainersRounded { get; init; }
        public int PurchaseOrders { get; init; }
        public DateTime? PostedAtUtc { get; init; }
        public string? PostedByName { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public int? CreatedBy { get; init; }
        public string? CreatedByName { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public ShortageDocumentListDto ToDto() => new()
        {
            Id = Id,
            DocumentNumber = DocumentNumber,
            Description = Description,
            DocumentDate = DocumentDate,
            BranchId = BranchId,
            BranchName = BranchName,
            WarehouseId = WarehouseId,
            WarehouseName = WarehouseName,
            SupplierId = SupplierId,
            SupplierCode = SupplierCode,
            SupplierName = SupplierName,
            LeadTimeMonths = LeadTimeMonths,
            MonthsOfHistory = MonthsOfHistory,
            Status = ShortageDocumentStatus.From(Status),
            TotalLines = TotalLines,
            TotalShortageBase = TotalShortageBase,
            TotalRequiredBase = TotalRequiredBase,
            TotalContainers = TotalContainers,
            ContainersRounded = ContainersRounded,
            PurchaseOrders = PurchaseOrders,
            PostedAtUtc = PostedAtUtc,
            PostedByName = PostedByName,
            CreatedAtUtc = CreatedAtUtc,
            CreatedBy = CreatedBy,
            CreatedByName = CreatedByName,
            UpdatedAtUtc = UpdatedAtUtc,
            RowVersion = RowVersion,
        };
    }

    public async Task<(IReadOnlyList<ShortageDocumentListDto> Items, int TotalCount)> SearchAsync(
        ShortageDocumentQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.WarehouseId,
            query.BranchId,
            query.SupplierId,
            Status = ShortageDocumentStatus.ToCode(query.Status),
            query.CreatedBy,
            DateFrom = query.DateFrom?.ToDateTime(TimeOnly.MinValue),
            DateTo = query.DateTo?.ToDateTime(TimeOnly.MinValue),
            SortColumn = SortColumns.FirstOrDefault(c => string.Equals(c, query.SortBy, StringComparison.OrdinalIgnoreCase))
                         ?? "DocumentDate",
            SortDirection = string.Equals(query.SortDir, "asc", StringComparison.OrdinalIgnoreCase) ? "ASC" : "DESC",
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<ListRow>(new CommandDefinition(
            "inventory.usp_ShortageDocument_Search", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var list = rows.AsList();
        var total = list.Count > 0 ? list[0].TotalCount : 0;
        return (list.Select(r => r.ToDto()).ToList(), total);
    }

    private sealed class HeaderRow
    {
        public int Id { get; init; }
        public string DocumentNumber { get; init; } = string.Empty;
        public string Description { get; init; } = string.Empty;
        public DateTime DocumentDate { get; init; }
        public int BranchId { get; init; }
        public string BranchCode { get; init; } = string.Empty;
        public string BranchName { get; init; } = string.Empty;
        public int WarehouseId { get; init; }
        public string WarehouseCode { get; init; } = string.Empty;
        public string WarehouseName { get; init; } = string.Empty;
        public int SupplierId { get; init; }
        public string SupplierCode { get; init; } = string.Empty;
        public string SupplierName { get; init; } = string.Empty;
        public decimal LeadTimeMonths { get; init; }
        public int MonthsOfHistory { get; init; }
        public string? Notes { get; init; }
        public byte Status { get; init; }
        public int TotalLines { get; init; }
        public int TotalShortageBase { get; init; }
        public int TotalRequiredBase { get; init; }
        public decimal TotalContainers { get; init; }
        public int ContainersRounded { get; init; }
        public decimal? ContainerUtilizationPct { get; init; }
        public DateTime? CalculatedAtUtc { get; init; }
        public DateTime? PostedAtUtc { get; init; }
        public int? PostedBy { get; init; }
        public string? PostedByName { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public int? CreatedBy { get; init; }
        public string? CreatedByName { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public int? UpdatedBy { get; init; }
        public string? UpdatedByName { get; init; }
        public byte[] RowVersion { get; init; } = [];
    }

    /// <summary>A line as the procedure returns it. LineNumber here, LineNo on the DTO — LINENO is reserved in T-SQL.</summary>
    private sealed class LineRow
    {
        public int Id { get; init; }
        public int LineNumber { get; init; }
        public int ItemId { get; init; }
        public string ItemCode { get; init; } = string.Empty;
        public string ItemName { get; init; } = string.Empty;
        public string BrandName { get; init; } = string.Empty;
        public string FamilyName { get; init; } = string.Empty;
        public bool IsBivac { get; init; }
        public int CurrentInventoryBase { get; init; }
        public int TransitBase { get; init; }
        public int OutstandingOrderBase { get; init; }
        public int StockPlusTransitBase { get; init; }
        public int TotalExpectedStockBase { get; init; }
        public decimal ExpectedMonthlySalesBase { get; init; }
        public decimal? ExpectedMonthlySalesManual { get; init; }
        public decimal EffectiveMonthlySales { get; init; }
        public decimal LeadTimeMonths { get; init; }
        public decimal ExpectedRequirementBase { get; init; }
        public int ShortageBase { get; init; }
        public decimal? CoverageMonths { get; init; }
        public int PurchaseItemUnitId { get; init; }
        public string PurchaseUnitName { get; init; } = string.Empty;
        public int PurchasePackingFormula { get; init; }
        public int RequiredQty { get; init; }
        public int RequiredBase { get; init; }
        public int? PcPerContainer { get; init; }
        public decimal? ContainerRequirement { get; init; }
        public int? DefaultPcPerContainer { get; init; }
        public int? MinQuantity { get; init; }
        public int? MaxQuantity { get; init; }
        public decimal? LastCost { get; init; }
        public string? Notes { get; init; }

        public ShortageDocumentLineDto ToDto() => new()
        {
            Id = Id,
            LineNo = LineNumber,
            ItemId = ItemId,
            ItemCode = ItemCode,
            ItemName = ItemName,
            BrandName = BrandName,
            FamilyName = FamilyName,
            IsBivac = IsBivac,
            CurrentInventoryBase = CurrentInventoryBase,
            TransitBase = TransitBase,
            OutstandingOrderBase = OutstandingOrderBase,
            StockPlusTransitBase = StockPlusTransitBase,
            TotalExpectedStockBase = TotalExpectedStockBase,
            ExpectedMonthlySalesBase = ExpectedMonthlySalesBase,
            ExpectedMonthlySalesManual = ExpectedMonthlySalesManual,
            EffectiveMonthlySales = EffectiveMonthlySales,
            LeadTimeMonths = LeadTimeMonths,
            ExpectedRequirementBase = ExpectedRequirementBase,
            ShortageBase = ShortageBase,
            CoverageMonths = CoverageMonths,
            PurchaseItemUnitId = PurchaseItemUnitId,
            PurchaseUnitName = PurchaseUnitName,
            PurchasePackingFormula = PurchasePackingFormula,
            RequiredQty = RequiredQty,
            RequiredBase = RequiredBase,
            PcPerContainer = PcPerContainer,
            ContainerRequirement = ContainerRequirement,
            DefaultPcPerContainer = DefaultPcPerContainer,
            MinQuantity = MinQuantity,
            MaxQuantity = MaxQuantity,
            LastCost = LastCost,
            Notes = Notes,
        };
    }

    private sealed class PurchaseOrderRow
    {
        public int Id { get; init; }
        public string? DocumentNumber { get; init; }
        public DateTime DocumentDate { get; init; }
        public byte Status { get; init; }
        public decimal TotalAmount { get; init; }
        public string CurrencyCode { get; init; } = string.Empty;
        public DateTime CreatedAtUtc { get; init; }

        public ShortagePurchaseOrderDto ToDto() => new()
        {
            Id = Id,
            DocumentNumber = DocumentNumber,
            DocumentDate = DocumentDate,
            Status = PurchaseDocumentStatus.From(Status),
            TotalAmount = TotalAmount,
            CurrencyCode = CurrencyCode,
            CreatedAtUtc = CreatedAtUtc,
        };
    }

    public async Task<ShortageDocumentDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();

        // Four result sets in one round trip, so the header's totals and the lines are from the same moment.
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "inventory.usp_ShortageDocument_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var header = await multi.ReadSingleOrDefaultAsync<HeaderRow>();
        if (header is null)
        {
            return null;
        }

        var lines = (await multi.ReadAsync<LineRow>()).AsList();
        var orders = (await multi.ReadAsync<PurchaseOrderRow>()).AsList();
        var audit = (await multi.ReadAsync<ShortageDocumentAuditDto>()).AsList();

        return new ShortageDocumentDto
        {
            Id = header.Id,
            DocumentNumber = header.DocumentNumber,
            Description = header.Description,
            DocumentDate = header.DocumentDate,
            BranchId = header.BranchId,
            BranchCode = header.BranchCode,
            BranchName = header.BranchName,
            WarehouseId = header.WarehouseId,
            WarehouseCode = header.WarehouseCode,
            WarehouseName = header.WarehouseName,
            SupplierId = header.SupplierId,
            SupplierCode = header.SupplierCode,
            SupplierName = header.SupplierName,
            LeadTimeMonths = header.LeadTimeMonths,
            MonthsOfHistory = header.MonthsOfHistory,
            Notes = header.Notes,
            Status = ShortageDocumentStatus.From(header.Status),
            TotalLines = header.TotalLines,
            TotalShortageBase = header.TotalShortageBase,
            TotalRequiredBase = header.TotalRequiredBase,
            TotalContainers = header.TotalContainers,
            ContainersRounded = header.ContainersRounded,
            ContainerUtilizationPct = header.ContainerUtilizationPct,
            CalculatedAtUtc = header.CalculatedAtUtc,
            PostedAtUtc = header.PostedAtUtc,
            PostedBy = header.PostedBy,
            PostedByName = header.PostedByName,
            CreatedAtUtc = header.CreatedAtUtc,
            CreatedBy = header.CreatedBy,
            CreatedByName = header.CreatedByName,
            UpdatedAtUtc = header.UpdatedAtUtc,
            UpdatedBy = header.UpdatedBy,
            UpdatedByName = header.UpdatedByName,
            RowVersion = header.RowVersion,
            Lines = lines.Select(l => l.ToDto()).ToList(),
            PurchaseOrders = orders.Select(o => o.ToDto()).ToList(),
            Audit = audit,
        };
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<int> SaveAsync(
        SaveShortageDocumentRequest request, int? id, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@Description", request.Description, DbType.String, size: 200);
        parameters.Add("@DocumentDate", request.DocumentDate.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@BranchId", request.BranchId, DbType.Int32);
        parameters.Add("@WarehouseId", request.WarehouseId, DbType.Int32);
        parameters.Add("@SupplierId", request.SupplierId, DbType.Int32);
        parameters.Add("@LeadTimeMonths", request.LeadTimeMonths, DbType.Decimal, precision: 6, scale: 2);
        parameters.Add("@MonthsOfHistory", request.MonthsOfHistory, DbType.Int32);
        parameters.Add("@Notes", request.Notes, DbType.String, size: 1000);
        parameters.Add("@Lines", ToLineTable(request.Lines).AsTableValuedParameter(LineTypeName));
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        try
        {
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.ExecuteAsync(new CommandDefinition(
                    "inventory.usp_ShortageDocument_Save", parameters,
                    commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            }, cancellationToken);

            return parameters.Get<int>("@NewId");
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public Task RecalculateAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("inventory.usp_ShortageDocument_Recalculate",
            new { Id = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task PostAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("inventory.usp_ShortageDocument_Post",
            new { Id = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("inventory.usp_ShortageDocument_Delete", new { Id = id, UserId = userId }, cancellationToken);

    public async Task<int> CreatePurchaseOrderAsync(
        int id, DateOnly? documentDate, DateOnly? expectedDate, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@DocumentDate", documentDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@ExpectedDate", expectedDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        try
        {
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.ExecuteAsync(new CommandDefinition(
                    "inventory.usp_ShortageDocument_CreatePurchaseOrder", parameters,
                    commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            }, cancellationToken);

            return parameters.Get<int>("@NewId");
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    private async Task ExecuteAsync(string procedure, object parameters, CancellationToken cancellationToken)
    {
        try
        {
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.ExecuteAsync(new CommandDefinition(
                    procedure, parameters, commandType: CommandType.StoredProcedure,
                    cancellationToken: cancellationToken));
            }, cancellationToken);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /* ── plumbing ─────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// The lines as a <see cref="DataTable"/> shaped like inventory.tvp_ShortageLine.
    ///
    /// COLUMN ORDER IS THE TYPE'S ORDER AND IS LOAD-BEARING — a table-valued parameter is sent
    /// positionally. Types are declared, not inferred: an all-null column infers as string and the
    /// server refuses the batch. A NULL here means something ("use the suggested quantity", "use the
    /// computed sales", "use the item's PC per container"), so nulls are sent as nulls, never as 0.
    /// </summary>
    private static DataTable ToLineTable(IReadOnlyList<SaveShortageDocumentLineRequest> lines)
    {
        var table = new DataTable();
        table.Columns.Add("LineNumber", typeof(int));
        table.Columns.Add("ItemId", typeof(int));
        table.Columns.Add("RequiredQty", typeof(int));
        table.Columns.Add("ExpectedMonthlySalesManual", typeof(decimal));
        table.Columns.Add("PcPerContainer", typeof(int));
        table.Columns.Add("Notes", typeof(string));

        // Numbered from the position in the list, not from what the client sent — one authority.
        var lineNumber = 1;
        foreach (var line in lines)
        {
            table.Rows.Add(
                lineNumber++,
                line.ItemId,
                (object?)line.RequiredQty ?? DBNull.Value,
                (object?)line.ExpectedMonthlySalesManual ?? DBNull.Value,
                (object?)line.PcPerContainer ?? DBNull.Value,
                (object?)line.Notes ?? DBNull.Value);
        }

        return table;
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
