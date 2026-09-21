using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class StockDocumentRepository : IStockDocumentRepository
{
    /// <summary>
    /// The table type as the server knows it. A table-valued parameter is matched by TYPE NAME, and a
    /// wrong one fails with a message about an invalid parameter that never mentions the type.
    /// </summary>
    private const string LineTypeName = "inventory.tvp_StockDocumentLine";

    /// <summary>The columns the search procedure will sort by; anything else falls back to the document date.</summary>
    private static readonly string[] SortColumns =
        ["DocumentNumber", "DocumentDate", "BranchName", "WarehouseName", "Status", "TotalCost", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public StockDocumentRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /* ── configuration and lookups ────────────────────────────────────────────────────────────── */

    public async Task<IReadOnlyList<DocumentTypeDto>> GetDocumentTypesAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<DocumentTypeDto>(new CommandDefinition(
            "inventory.usp_DocumentType_List", commandType: CommandType.StoredProcedure,
            cancellationToken: cancellationToken));

        return rows.AsList();
    }

    public async Task UpdateDocumentTypeAsync(
        int id, UpdateDocumentTypeRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@Name", request.Name, DbType.String, size: 100);
        parameters.Add("@NumberPrefix", request.NumberPrefix, DbType.String, size: 10);
        parameters.Add("@NumberLength", request.NumberLength, DbType.Byte);
        parameters.Add("@NumberOnPost", request.NumberOnPost, DbType.Boolean);
        parameters.Add("@RequiresReason", request.RequiresReason, DbType.Boolean);
        parameters.Add("@DefaultPricing", request.DefaultPricing, DbType.String, size: 10);
        parameters.Add("@PriceEditable", request.PriceEditable, DbType.Boolean);
        parameters.Add("@NumberPerBranch", request.NumberPerBranch, DbType.Boolean);
        parameters.Add("@IsActive", request.IsActive, DbType.Boolean);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@YearInNumber", request.YearInNumber, DbType.Boolean);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_DocumentType_Update", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<IReadOnlyList<StockReasonDto>> GetStockReasonsAsync(
        short? direction, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<StockReasonDto>(new CommandDefinition(
            "inventory.usp_StockReason_Lookup", new { Direction = direction },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return rows.AsList();
    }

    /// <summary>
    /// Straight to the function rather than through a procedure, because that is all there is to ask:
    /// the grid wants one number per item and warehouse while somebody is typing.
    /// </summary>
    public async Task<decimal> GetOnHandAsync(int itemId, int warehouseId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.ExecuteScalarAsync<decimal?>(new CommandDefinition(
            "SELECT inventory.fn_StockOnHand(@ItemId, @WarehouseId);",
            new { ItemId = itemId, WarehouseId = warehouseId },
            cancellationToken: cancellationToken)) ?? 0m;
    }

    /* ── reading documents ────────────────────────────────────────────────────────────────────── */

    /// <summary>The list row exactly as the procedure returns it, before the status becomes a word.</summary>
    private sealed class ListRow
    {
        public int Id { get; init; }
        public string DocumentTypeCode { get; init; } = string.Empty;
        public string DocumentTypeName { get; init; } = string.Empty;
        public short StockDirection { get; init; }
        public string? DocumentNumber { get; init; }
        public DateTime DocumentDate { get; init; }
        public int BranchId { get; init; }
        public string BranchName { get; init; } = string.Empty;
        public int WarehouseId { get; init; }
        public string WarehouseName { get; init; } = string.Empty;
        public int? ReasonId { get; init; }
        public string? ReasonName { get; init; }
        public string? ReferenceNo { get; init; }
        public string CurrencyCode { get; init; } = string.Empty;
        public byte Status { get; init; }
        public int TotalItems { get; init; }
        public decimal TotalQuantity { get; init; }
        public decimal TotalCost { get; init; }
        public DateTime? PostedAtUtc { get; init; }
        public string? PostedByName { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public string? CreatedByName { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public StockDocumentListDto ToDto() => new()
        {
            Id = Id,
            DocumentTypeCode = DocumentTypeCode,
            DocumentTypeName = DocumentTypeName,
            StockDirection = StockDirection,
            DocumentNumber = DocumentNumber,
            DocumentDate = DocumentDate,
            BranchId = BranchId,
            BranchName = BranchName,
            WarehouseId = WarehouseId,
            WarehouseName = WarehouseName,
            ReasonId = ReasonId,
            ReasonName = ReasonName,
            ReferenceNo = ReferenceNo,
            CurrencyCode = CurrencyCode,
            Status = StockDocumentStatus.From(Status),
            TotalItems = TotalItems,
            TotalQuantity = TotalQuantity,
            TotalCost = TotalCost,
            PostedAtUtc = PostedAtUtc,
            PostedByName = PostedByName,
            CreatedAtUtc = CreatedAtUtc,
            CreatedByName = CreatedByName,
            RowVersion = RowVersion,
        };
    }

    public async Task<(IReadOnlyList<StockDocumentListDto> Items, int TotalCount)> SearchAsync(
        StockDocumentQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            query.DocumentTypeCode,
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.BranchId,
            query.WarehouseId,
            Status = ToStatusCode(query.Status),
            DateFrom = query.DateFrom?.ToDateTime(TimeOnly.MinValue),
            DateTo = query.DateTo?.ToDateTime(TimeOnly.MinValue),
            SortColumn = ResolveSortColumn(query.SortBy),
            SortDirection = string.Equals(query.SortDir, "asc", StringComparison.OrdinalIgnoreCase) ? "ASC" : "DESC",
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<ListRow>(new CommandDefinition(
                "inventory.usp_StockDocument_Search", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var list = rows.AsList();
            // The procedure repeats COUNT(*) OVER () on every row; no rows means nothing matched.
            var total = list.Count > 0 ? list[0].TotalCount : 0;
            return (list.Select(r => r.ToDto()).ToList(), total);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>The header row as the procedure returns it — the status is still a number here.</summary>
    private sealed class HeaderRow
    {
        public int Id { get; init; }
        public int DocumentTypeId { get; init; }
        public string DocumentTypeCode { get; init; } = string.Empty;
        public string DocumentTypeName { get; init; } = string.Empty;
        public short StockDirection { get; init; }
        public bool NumberOnPost { get; init; }
        public string? DocumentNumber { get; init; }
        public DateTime DocumentDate { get; init; }
        public int BranchId { get; init; }
        public string BranchCode { get; init; } = string.Empty;
        public string BranchName { get; init; } = string.Empty;
        public int WarehouseId { get; init; }
        public string WarehouseCode { get; init; } = string.Empty;
        public string WarehouseName { get; init; } = string.Empty;
        public int? ReasonId { get; init; }
        public string? ReasonCode { get; init; }
        public string? ReasonName { get; init; }
        public string? ReferenceNo { get; init; }
        public int CurrencyId { get; init; }
        public string CurrencyCode { get; init; } = string.Empty;
        public byte DecimalPlaces { get; init; }
        public string? Notes { get; init; }
        public byte Status { get; init; }
        public int TotalItems { get; init; }
        public decimal TotalQuantity { get; init; }
        public decimal TotalCost { get; init; }
        public DateTime? PostedAtUtc { get; init; }
        public string? PostedByName { get; init; }
        public DateTime? CancelledAtUtc { get; init; }
        public string? CancelledByName { get; init; }
        public string? CancelReason { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public string? CreatedByName { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public string? UpdatedByName { get; init; }
        public byte[] RowVersion { get; init; } = [];
    }

    /// <summary>
    /// A line as the procedure returns it.
    ///
    /// LineNumber HERE, LineNo ON THE DTO. LINENO is a reserved T-SQL keyword, so the column cannot
    /// carry the client's name without brackets in every statement that touches it; this class is the
    /// one place the two names meet.
    /// </summary>
    private sealed class LineRow
    {
        public int Id { get; init; }
        public int LineNumber { get; init; }
        public int ItemId { get; init; }
        public string ItemCode { get; init; } = string.Empty;
        public string ItemName { get; init; } = string.Empty;
        public int ItemUnitId { get; init; }
        public string UnitTypeName { get; init; } = string.Empty;
        public string? SkuCode { get; init; }
        public string? Barcode { get; init; }
        public int PackingFormula { get; init; }
        public int WarehouseId { get; init; }
        public string WarehouseCode { get; init; } = string.Empty;
        public string WarehouseName { get; init; } = string.Empty;
        public DateTime? ExpiryDate { get; init; }
        public int Quantity { get; init; }
        public decimal QuantityBase { get; init; }
        public decimal UnitCost { get; init; }
        public decimal LineTotal { get; init; }
        public string? Notes { get; init; }
        public decimal OnHandBase { get; init; }

        public StockDocumentLineDto ToDto() => new()
        {
            Id = Id,
            LineNo = LineNumber,
            ItemId = ItemId,
            ItemCode = ItemCode,
            ItemName = ItemName,
            ItemUnitId = ItemUnitId,
            UnitTypeName = UnitTypeName,
            SkuCode = SkuCode,
            Barcode = Barcode,
            PackingFormula = PackingFormula,
            WarehouseId = WarehouseId,
            WarehouseCode = WarehouseCode,
            WarehouseName = WarehouseName,
            ExpiryDate = ExpiryDate,
            Quantity = Quantity,
            QuantityBase = QuantityBase,
            UnitCost = UnitCost,
            LineTotal = LineTotal,
            Notes = Notes,
            OnHandBase = OnHandBase,
        };
    }

    public async Task<StockDocumentDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();

        // FOUR RESULT SETS IN ONE ROUND TRIP. A document is a header, its lines, its files and its
        // history, and a screen that fetched them separately could show a header from one moment and
        // lines from another.
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "inventory.usp_StockDocument_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var header = await multi.ReadSingleOrDefaultAsync<HeaderRow>();
        if (header is null)
        {
            return null;
        }

        var lines = (await multi.ReadAsync<LineRow>()).AsList();
        var files = (await multi.ReadAsync<StockDocumentFileDto>()).AsList();
        var audit = (await multi.ReadAsync<StockDocumentAuditDto>()).AsList();

        return new StockDocumentDto
        {
            Id = header.Id,
            DocumentTypeId = header.DocumentTypeId,
            DocumentTypeCode = header.DocumentTypeCode,
            DocumentTypeName = header.DocumentTypeName,
            StockDirection = header.StockDirection,
            NumberOnPost = header.NumberOnPost,
            DocumentNumber = header.DocumentNumber,
            DocumentDate = header.DocumentDate,
            BranchId = header.BranchId,
            BranchCode = header.BranchCode,
            BranchName = header.BranchName,
            WarehouseId = header.WarehouseId,
            WarehouseCode = header.WarehouseCode,
            WarehouseName = header.WarehouseName,
            ReasonId = header.ReasonId,
            ReasonCode = header.ReasonCode,
            ReasonName = header.ReasonName,
            ReferenceNo = header.ReferenceNo,
            CurrencyId = header.CurrencyId,
            CurrencyCode = header.CurrencyCode,
            DecimalPlaces = header.DecimalPlaces,
            Notes = header.Notes,
            Status = StockDocumentStatus.From(header.Status),
            TotalItems = header.TotalItems,
            TotalQuantity = header.TotalQuantity,
            TotalCost = header.TotalCost,
            PostedAtUtc = header.PostedAtUtc,
            PostedByName = header.PostedByName,
            CancelledAtUtc = header.CancelledAtUtc,
            CancelledByName = header.CancelledByName,
            CancelReason = header.CancelReason,
            CreatedAtUtc = header.CreatedAtUtc,
            CreatedByName = header.CreatedByName,
            UpdatedAtUtc = header.UpdatedAtUtc,
            UpdatedByName = header.UpdatedByName,
            RowVersion = header.RowVersion,
            Lines = lines.Select(l => l.ToDto()).ToList(),
            Files = files,
            Audit = audit,
        };
    }

    /* ── writing documents ────────────────────────────────────────────────────────────────────── */

    public async Task<int> SaveAsync(
        SaveStockDocumentRequest request, int? id, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@DocumentTypeCode", request.DocumentTypeCode, DbType.String, size: 20);
        parameters.Add("@DocumentDate", request.DocumentDate.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@BranchId", request.BranchId, DbType.Int32);
        parameters.Add("@WarehouseId", request.WarehouseId, DbType.Int32);
        parameters.Add("@ReasonId", request.ReasonId, DbType.Int32);
        parameters.Add("@ReferenceNo", request.ReferenceNo, DbType.String, size: 100);
        parameters.Add("@Notes", request.Notes, DbType.String, size: 1000);
        parameters.Add("@Lines", ToLineTable(request.Lines).AsTableValuedParameter(LineTypeName));
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_StockDocument_Save", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return parameters.Get<int>("@NewId");
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public Task PostAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("inventory.usp_StockDocument_Post",
            new { Id = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("inventory.usp_StockDocument_Cancel",
            new { Id = id, Reason = reason, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("inventory.usp_StockDocument_Delete", new { Id = id, UserId = userId }, cancellationToken);

    public Task DeleteFileAsync(int fileId, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("inventory.usp_StockDocumentFile_Delete", new { Id = fileId, UserId = userId }, cancellationToken);

    public async Task<int> AddFileAsync(
        int documentId, string fileName, string contentType, byte[] content, int userId,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@DocumentId", documentId, DbType.Int32);
        parameters.Add("@FileName", fileName, DbType.String, size: 255);
        parameters.Add("@ContentType", contentType, DbType.String, size: 100);
        parameters.Add("@SizeBytes", content.Length, DbType.Int32);
        parameters.Add("@Content", content, DbType.Binary, size: -1);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_StockDocumentFile_Add", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return parameters.Get<int>("@NewId");
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<StockDocumentFileContent?> GetFileAsync(int fileId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<StockDocumentFileContent>(new CommandDefinition(
            "inventory.usp_StockDocumentFile_Get", new { Id = fileId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    /// <summary>The shape every write shares: run the procedure, translate a deliberate THROW.</summary>
    private async Task ExecuteAsync(string procedure, object parameters, CancellationToken cancellationToken)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                procedure, parameters, commandType: CommandType.StoredProcedure,
                cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /* ── plumbing ─────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// The lines as a <see cref="DataTable"/> shaped like inventory.tvp_StockDocumentLine.
    ///
    /// THE COLUMN ORDER IS THE TYPE'S ORDER AND IS LOAD-BEARING: a table-valued parameter is sent
    /// positionally, whatever the columns are called, so swapping two Add calls silently puts the
    /// warehouse id in the unit column. Kept in the same order as the CREATE TYPE.
    ///
    /// The types are declared rather than inferred, because a column that is null on every row infers
    /// as string and the server then refuses the whole batch.
    /// </summary>
    private static DataTable ToLineTable(IReadOnlyList<SaveStockDocumentLineRequest> lines)
    {
        var table = new DataTable();
        table.Columns.Add("LineNumber", typeof(int));
        table.Columns.Add("ItemId", typeof(int));
        table.Columns.Add("ItemUnitId", typeof(int));
        table.Columns.Add("WarehouseId", typeof(int));
        table.Columns.Add("ExpiryDate", typeof(DateTime));
        table.Columns.Add("Quantity", typeof(int));
        table.Columns.Add("UnitCost", typeof(decimal));
        table.Columns.Add("Notes", typeof(string));

        // Numbered from the position in the list rather than from what the client sent: the grid can
        // delete row 2 of five and post the rest, and the type's primary key on LineNumber would
        // refuse a gap-free-but-duplicated sequence. One authority, and it is the order of the rows.
        var lineNumber = 1;
        foreach (var line in lines)
        {
            table.Rows.Add(
                lineNumber++,
                line.ItemId,
                line.ItemUnitId,
                line.WarehouseId,
                line.ExpiryDate is { } expiry ? expiry.ToDateTime(TimeOnly.MinValue) : DBNull.Value,
                line.Quantity,
                (object?)line.UnitCost ?? DBNull.Value,
                (object?)line.Notes ?? DBNull.Value);
        }

        return table;
    }

    /// <summary>Base64 back to the eight bytes SQL Server compares. A malformed one is treated as absent rather than throwing.</summary>
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

    private static byte? ToStatusCode(string? status) => status switch
    {
        StockDocumentStatus.Draft => StockDocumentStatus.DraftCode,
        StockDocumentStatus.Posted => StockDocumentStatus.PostedCode,
        StockDocumentStatus.Cancelled => StockDocumentStatus.CancelledCode,
        _ => null,
    };

    private static string ResolveSortColumn(string? sortBy)
        => SortColumns.FirstOrDefault(c => string.Equals(c, sortBy, StringComparison.OrdinalIgnoreCase))
           ?? "DocumentDate";
}
