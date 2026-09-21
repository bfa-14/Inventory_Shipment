using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class PurchaseDocumentRepository : IPurchaseDocumentRepository
{
    /// <summary>Matched by TYPE NAME on the server; a wrong one fails with a message that never mentions the type.</summary>
    private const string LineTypeName = "purchase.tvp_PurchaseDocumentLine";
    private const string ShippedLineTypeName = "purchase.tvp_ShippedLine";

    /// <summary>The columns the search procedure will sort by; anything else falls back to the document date.</summary>
    private static readonly string[] SortColumns =
        ["DocumentNumber", "DocumentDate", "SupplierName", "Status", "TotalAmount", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public PurchaseDocumentRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    /// <summary>The list row as the procedure returns it, before the status becomes a word.</summary>
    private sealed class ListRow
    {
        public int Id { get; init; }
        public string DocumentTypeCode { get; init; } = string.Empty;
        public string DocumentTypeName { get; init; } = string.Empty;
        public short StockDirection { get; init; }
        public string? DocumentNumber { get; init; }
        public DateTime DocumentDate { get; init; }
        public DateTime? ExpectedDate { get; init; }
        public int BranchId { get; init; }
        public string BranchName { get; init; } = string.Empty;
        public int WarehouseId { get; init; }
        public string WarehouseName { get; init; } = string.Empty;
        public int SupplierId { get; init; }
        public string SupplierCode { get; init; } = string.Empty;
        public string SupplierName { get; init; } = string.Empty;
        public int CurrencyId { get; init; }
        public string CurrencyCode { get; init; } = string.Empty;
        public string? CurrencySymbol { get; init; }
        public byte DecimalPlaces { get; init; }
        public decimal ExchangeRate { get; init; }
        public string? SupplierReference { get; init; }
        public byte Status { get; init; }
        public int TotalItems { get; init; }
        public decimal TotalQuantity { get; init; }
        public decimal Subtotal { get; init; }
        public decimal TotalDiscount { get; init; }
        public decimal TotalAmount { get; init; }
        public decimal TotalAmountBase { get; init; }
        public int? SourceDocumentId { get; init; }
        public string? SourceDocumentNumber { get; init; }
        public decimal? ReceivedPercent { get; init; }
        public DateTime? PostedAtUtc { get; init; }
        public string? PostedByName { get; init; }
        public DateTime? CancelledAtUtc { get; init; }
        public DateTime? ClosedAtUtc { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public string? CreatedByName { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public PurchaseDocumentListDto ToDto() => new()
        {
            Id = Id,
            DocumentTypeCode = DocumentTypeCode,
            DocumentTypeName = DocumentTypeName,
            StockDirection = StockDirection,
            DocumentNumber = DocumentNumber,
            DocumentDate = DocumentDate,
            ExpectedDate = ExpectedDate,
            BranchId = BranchId,
            BranchName = BranchName,
            WarehouseId = WarehouseId,
            WarehouseName = WarehouseName,
            SupplierId = SupplierId,
            SupplierCode = SupplierCode,
            SupplierName = SupplierName,
            CurrencyId = CurrencyId,
            CurrencyCode = CurrencyCode,
            CurrencySymbol = CurrencySymbol,
            DecimalPlaces = DecimalPlaces,
            ExchangeRate = ExchangeRate,
            SupplierReference = SupplierReference,
            Status = PurchaseDocumentStatus.From(Status),
            TotalItems = TotalItems,
            TotalQuantity = TotalQuantity,
            Subtotal = Subtotal,
            TotalDiscount = TotalDiscount,
            TotalAmount = TotalAmount,
            TotalAmountBase = TotalAmountBase,
            SourceDocumentId = SourceDocumentId,
            SourceDocumentNumber = SourceDocumentNumber,
            ReceivedPercent = ReceivedPercent,
            PostedAtUtc = PostedAtUtc,
            PostedByName = PostedByName,
            CancelledAtUtc = CancelledAtUtc,
            ClosedAtUtc = ClosedAtUtc,
            CreatedAtUtc = CreatedAtUtc,
            CreatedByName = CreatedByName,
            UpdatedAtUtc = UpdatedAtUtc,
            RowVersion = RowVersion,
        };
    }

    public async Task<(IReadOnlyList<PurchaseDocumentListDto> Items, int TotalCount)> SearchAsync(
        PurchaseDocumentQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            DocumentTypeCode = PurchaseDocumentTypes.Normalize(query.DocumentTypeCode),
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.BranchId,
            query.WarehouseId,
            query.SupplierId,
            Status = PurchaseDocumentStatus.ToCode(query.Status),
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
                "purchase.usp_PurchaseDocument_Search", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var list = rows.AsList();
            var total = list.Count > 0 ? list[0].TotalCount : 0;
            return (list.Select(r => r.ToDto()).ToList(), total);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

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
        public DateTime? ExpectedDate { get; init; }
        public int BranchId { get; init; }
        public string BranchCode { get; init; } = string.Empty;
        public string BranchName { get; init; } = string.Empty;
        public int WarehouseId { get; init; }
        public string WarehouseCode { get; init; } = string.Empty;
        public string WarehouseName { get; init; } = string.Empty;
        public int SupplierId { get; init; }
        public string SupplierCode { get; init; } = string.Empty;
        public string SupplierName { get; init; } = string.Empty;
        public string? SupplierPhone { get; init; }
        public string? SupplierEmail { get; init; }
        public string? SupplierAddress { get; init; }
        public int CurrencyId { get; init; }
        public string CurrencyCode { get; init; } = string.Empty;
        public string CurrencyName { get; init; } = string.Empty;
        public string? CurrencySymbol { get; init; }
        public byte DecimalPlaces { get; init; }
        public bool IsBaseCurrency { get; init; }
        public byte RateType { get; init; }
        public decimal ExchangeRate { get; init; }
        public string? BaseCurrencyCode { get; init; }
        public string? SupplierReference { get; init; }
        public string? Notes { get; init; }
        public byte Status { get; init; }
        public int TotalItems { get; init; }
        public decimal TotalQuantity { get; init; }
        public decimal Subtotal { get; init; }
        public decimal TotalDiscount { get; init; }
        public decimal TotalAmount { get; init; }
        public decimal TotalAmountBase { get; init; }
        public decimal TotalChargesBase { get; init; }
        public decimal TotalLandedCostBase { get; init; }
        public int? SourceDocumentId { get; init; }
        public string? SourceDocumentNumber { get; init; }
        public string? SourceDocumentTypeCode { get; init; }
        public int? SourceShortageId { get; init; }
        public string? SourceShortageNumber { get; init; }
        public DateTime? PostedAtUtc { get; init; }
        public string? PostedByName { get; init; }
        public DateTime? CancelledAtUtc { get; init; }
        public string? CancelledByName { get; init; }
        public string? CancelReason { get; init; }
        public DateTime? ClosedAtUtc { get; init; }
        public string? ClosedByName { get; init; }
        public string? CloseReason { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public string? CreatedByName { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
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
        public decimal UnitPrice { get; init; }
        public decimal DiscountPercent { get; init; }
        public decimal LineDiscount { get; init; }
        public decimal LineTotal { get; init; }
        public decimal? UnitCostBase { get; init; }
        public decimal? LandedCostBase { get; init; }
        public decimal? FobCostBase { get; init; }
        public decimal AllocatedChargesBase { get; init; }
        public decimal ReceivedQuantityBase { get; init; }
        public decimal ReturnedQuantityBase { get; init; }
        public decimal? RemainingBase { get; init; }
        public decimal ShippedQuantityBase { get; init; }
        public decimal TransitBase { get; init; }
        public int? ImportRowNumber { get; init; }
        public string? Notes { get; init; }
        public int? SourceLineId { get; init; }
        public decimal OnHandBase { get; init; }
        public decimal? ItemLastCost { get; init; }
        public decimal? ItemAverageCost { get; init; }
        public decimal? ItemFobCost { get; init; }

        public PurchaseDocumentLineDto ToDto() => new()
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
            UnitPrice = UnitPrice,
            DiscountPercent = DiscountPercent,
            LineDiscount = LineDiscount,
            LineTotal = LineTotal,
            UnitCostBase = UnitCostBase,
            LandedCostBase = LandedCostBase,
            FobCostBase = FobCostBase,
            AllocatedChargesBase = AllocatedChargesBase,
            ReceivedQuantityBase = ReceivedQuantityBase,
            ReturnedQuantityBase = ReturnedQuantityBase,
            RemainingBase = RemainingBase,
            ShippedQuantityBase = ShippedQuantityBase,
            TransitBase = TransitBase,
            ImportRowNumber = ImportRowNumber,
            Notes = Notes,
            SourceLineId = SourceLineId,
            OnHandBase = OnHandBase,
            ItemLastCost = ItemLastCost,
            ItemAverageCost = ItemAverageCost,
            ItemFobCost = ItemFobCost,
        };
    }

    private sealed class LinkedRow
    {
        public string Relation { get; init; } = string.Empty;
        public int Id { get; init; }
        public string DocumentTypeCode { get; init; } = string.Empty;
        public string DocumentTypeName { get; init; } = string.Empty;
        public string? DocumentNumber { get; init; }
        public DateTime DocumentDate { get; init; }
        public byte Status { get; init; }
        public decimal TotalAmount { get; init; }
        public string CurrencyCode { get; init; } = string.Empty;

        public LinkedPurchaseDocumentDto ToDto() => new()
        {
            Relation = Relation,
            Id = Id,
            DocumentTypeCode = DocumentTypeCode,
            DocumentTypeName = DocumentTypeName,
            DocumentNumber = DocumentNumber,
            DocumentDate = DocumentDate,
            Status = PurchaseDocumentStatus.From(Status),
            TotalAmount = TotalAmount,
            CurrencyCode = CurrencyCode,
        };
    }

    public async Task<PurchaseDocumentDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();

        // Six result sets in one round trip, so the header, the lines, the chain and the charges are
        // from the same moment — a charge allocated between two reads would otherwise not add up.
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "purchase.usp_PurchaseDocument_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var header = await multi.ReadSingleOrDefaultAsync<HeaderRow>();
        if (header is null)
        {
            return null;
        }

        var lines = (await multi.ReadAsync<LineRow>()).AsList();
        var files = (await multi.ReadAsync<PurchaseDocumentFileDto>()).AsList();
        var audit = (await multi.ReadAsync<PurchaseDocumentAuditDto>()).AsList();
        var linked = (await multi.ReadAsync<LinkedRow>()).AsList();
        var charges = (await multi.ReadAsync<PurchaseChargeRow>()).AsList();

        return new PurchaseDocumentDto
        {
            Id = header.Id,
            DocumentTypeId = header.DocumentTypeId,
            DocumentTypeCode = header.DocumentTypeCode,
            DocumentTypeName = header.DocumentTypeName,
            StockDirection = header.StockDirection,
            NumberOnPost = header.NumberOnPost,
            DocumentNumber = header.DocumentNumber,
            DocumentDate = header.DocumentDate,
            ExpectedDate = header.ExpectedDate,
            BranchId = header.BranchId,
            BranchCode = header.BranchCode,
            BranchName = header.BranchName,
            WarehouseId = header.WarehouseId,
            WarehouseCode = header.WarehouseCode,
            WarehouseName = header.WarehouseName,
            SupplierId = header.SupplierId,
            SupplierCode = header.SupplierCode,
            SupplierName = header.SupplierName,
            SupplierPhone = header.SupplierPhone,
            SupplierEmail = header.SupplierEmail,
            SupplierAddress = header.SupplierAddress,
            CurrencyId = header.CurrencyId,
            CurrencyCode = header.CurrencyCode,
            CurrencyName = header.CurrencyName,
            CurrencySymbol = header.CurrencySymbol,
            DecimalPlaces = header.DecimalPlaces,
            IsBaseCurrency = header.IsBaseCurrency,
            RateType = header.RateType,
            ExchangeRate = header.ExchangeRate,
            BaseCurrencyCode = header.BaseCurrencyCode,
            SupplierReference = header.SupplierReference,
            Notes = header.Notes,
            Status = PurchaseDocumentStatus.From(header.Status),
            TotalItems = header.TotalItems,
            TotalQuantity = header.TotalQuantity,
            Subtotal = header.Subtotal,
            TotalDiscount = header.TotalDiscount,
            TotalAmount = header.TotalAmount,
            TotalAmountBase = header.TotalAmountBase,
            TotalChargesBase = header.TotalChargesBase,
            TotalLandedCostBase = header.TotalLandedCostBase,
            SourceDocumentId = header.SourceDocumentId,
            SourceDocumentNumber = header.SourceDocumentNumber,
            SourceDocumentTypeCode = header.SourceDocumentTypeCode,
            SourceShortageId = header.SourceShortageId,
            SourceShortageNumber = header.SourceShortageNumber,
            PostedAtUtc = header.PostedAtUtc,
            PostedByName = header.PostedByName,
            CancelledAtUtc = header.CancelledAtUtc,
            CancelledByName = header.CancelledByName,
            CancelReason = header.CancelReason,
            ClosedAtUtc = header.ClosedAtUtc,
            ClosedByName = header.ClosedByName,
            CloseReason = header.CloseReason,
            CreatedAtUtc = header.CreatedAtUtc,
            CreatedByName = header.CreatedByName,
            UpdatedAtUtc = header.UpdatedAtUtc,
            UpdatedByName = header.UpdatedByName,
            RowVersion = header.RowVersion,
            Lines = lines.Select(l => l.ToDto()).ToList(),
            Files = files,
            Audit = audit,
            Linked = linked.Select(l => l.ToDto()).ToList(),
            Charges = charges.Select(c => c.ToDto()).ToList(),
        };
    }

    /// <summary>
    /// Four columns rather than the five result sets of the Get: this runs before every action, to
    /// find out which permission the action needs, and is the one read in this class not behind a
    /// procedure — it asks nothing the procedures would compute.
    /// </summary>
    public async Task<PurchaseDocumentStub?> GetStubAsync(int id, CancellationToken cancellationToken = default)
    {
        const string sql = """
            SELECT d.Id, dt.Code AS DocumentTypeCode, d.Status, d.DocumentNumber
            FROM purchase.PurchaseDocuments d
            INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
            WHERE d.Id = @Id;
            """;

        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<PurchaseDocumentStub>(new CommandDefinition(
            sql, new { Id = id }, cancellationToken: cancellationToken));
    }

    public async Task<PurchaseRateResolutionDto?> ResolveRateAsync(
        int currencyId, byte rateType, DateOnly? asOfDate, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<PurchaseRateResolutionDto>(new CommandDefinition(
            "masterdata.usp_ExchangeRate_Resolve",
            new
            {
                CurrencyId = currencyId,
                RateType = rateType,
                AsOfDate = asOfDate?.ToDateTime(TimeOnly.MinValue),
            },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<int> SaveAsync(
        SavePurchaseDocumentRequest request, int? id, decimal maxDiscountPercent, int userId,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@DocumentTypeCode", PurchaseDocumentTypes.Normalize(request.DocumentTypeCode) ?? request.DocumentTypeCode, DbType.String, size: 20);
        parameters.Add("@DocumentDate", request.DocumentDate.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@ExpectedDate", request.ExpectedDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@BranchId", request.BranchId, DbType.Int32);
        parameters.Add("@WarehouseId", request.WarehouseId, DbType.Int32);
        parameters.Add("@SupplierId", request.SupplierId, DbType.Int32);
        parameters.Add("@CurrencyId", request.CurrencyId, DbType.Int32);
        parameters.Add("@RateType", request.RateType, DbType.Byte);
        parameters.Add("@ExchangeRate", request.ExchangeRate, DbType.Decimal);
        parameters.Add("@SupplierReference", request.SupplierReference, DbType.String, size: 100);
        parameters.Add("@Notes", request.Notes, DbType.String, size: 1000);
        parameters.Add("@Lines", ToLineTable(request.Lines, request.WarehouseId).AsTableValuedParameter(LineTypeName));
        parameters.Add("@MaxDiscountPercent", maxDiscountPercent, DbType.Decimal);
        parameters.Add("@SourceDocumentId", request.SourceDocumentId, DbType.Int32);
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        try
        {
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.ExecuteAsync(new CommandDefinition(
                    "purchase.usp_PurchaseDocument_Save", parameters,
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
        => ExecuteAsync("purchase.usp_PurchaseDocument_Post",
            new { Id = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_PurchaseDocument_Cancel",
            new { Id = id, Reason = reason, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task CloseAsync(int id, string? reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_PurchaseDocument_Close",
            new { Id = id, Reason = reason, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_PurchaseDocument_Delete", new { Id = id, UserId = userId }, cancellationToken);

    /// <summary>
    /// The charges of a DRAFT invoice, replacing whatever was there. Allocation is not done here:
    /// posting is what spreads them over the lines, because only then are the lines final.
    /// </summary>
    public Task SetChargesAsync(
        int id, SetPurchaseChargesRequest request, byte[]? rowVersion, int userId,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@DocumentId", id, DbType.Int32);
        parameters.Add("@Charges", PurchaseChargeTables.Charges(request.Charges).AsTableValuedParameter(PurchaseChargeTables.ChargeTypeName));
        parameters.Add("@ManualAllocations", PurchaseChargeTables.ManualAllocations(request.ManualAllocations, request.Charges).AsTableValuedParameter(PurchaseChargeTables.ManualAllocationTypeName));
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);

        return ExecuteAsync("purchase.usp_PurchaseDocument_SetCharges", parameters, cancellationToken);
    }

    /// <summary>An EMPTY table is the procedure's "everything shipped"; the table is sent either way, never null.</summary>
    public Task MarkShippedAsync(
        int id, IReadOnlyList<ShippedLineRequest> lines, byte[]? rowVersion, int userId,
        CancellationToken cancellationToken = default)
    {
        var table = new DataTable();
        table.Columns.Add("LineId", typeof(int));
        table.Columns.Add("ShippedQuantityBase", typeof(int));
        foreach (var line in lines)
        {
            table.Rows.Add(line.LineId, line.ShippedQuantityBase);
        }

        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@Lines", table.AsTableValuedParameter(ShippedLineTypeName));
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);

        return ExecuteAsync("purchase.usp_PurchaseDocument_MarkShipped", parameters, cancellationToken);
    }

    public async Task<int> CreateFromSourceAsync(
        int sourceId, string targetTypeCode, DateOnly? documentDate, int userId,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@SourceId", sourceId, DbType.Int32);
        parameters.Add("@TargetTypeCode", targetTypeCode, DbType.String, size: 20);
        parameters.Add("@DocumentDate", documentDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        try
        {
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.ExecuteAsync(new CommandDefinition(
                    "purchase.usp_PurchaseDocument_CreateFromSource", parameters,
                    commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            }, cancellationToken);

            return parameters.Get<int>("@NewId");
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public Task DeleteFileAsync(int fileId, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_PurchaseDocumentFile_Delete", new { Id = fileId, UserId = userId }, cancellationToken);

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
                "purchase.usp_PurchaseDocumentFile_Add", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return parameters.Get<int>("@NewId");
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<PurchaseDocumentFileContent?> GetFileAsync(int fileId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<PurchaseDocumentFileContent>(new CommandDefinition(
            "purchase.usp_PurchaseDocumentFile_Get", new { Id = fileId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    /// <summary>
    /// One procedure call, run again if SQL Server made it the deadlock victim: posting an invoice
    /// updates the order's lines then its header, and a reader of that order arriving between the
    /// two is enough for one of them to be killed. The transaction rolled back; the retry is clean.
    /// </summary>
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
    /// The lines as a <see cref="DataTable"/> shaped like purchase.tvp_PurchaseDocumentLine.
    ///
    /// COLUMN ORDER IS THE TYPE'S ORDER AND IS LOAD-BEARING — a table-valued parameter is sent
    /// positionally. Kept in the same order as the CREATE TYPE; types declared, not inferred, because
    /// an all-null column infers as string and the server refuses the batch. The warehouse column is
    /// filled with the header's: one document, one warehouse, and the engine ignores it anyway.
    /// </summary>
    private static DataTable ToLineTable(IReadOnlyList<SavePurchaseDocumentLineRequest> lines, int warehouseId)
    {
        var table = new DataTable();
        table.Columns.Add("LineNumber", typeof(int));
        table.Columns.Add("ItemId", typeof(int));
        table.Columns.Add("ItemUnitId", typeof(int));
        table.Columns.Add("WarehouseId", typeof(int));
        table.Columns.Add("ExpiryDate", typeof(DateTime));
        table.Columns.Add("Quantity", typeof(int));
        table.Columns.Add("UnitPrice", typeof(decimal));
        table.Columns.Add("DiscountPercent", typeof(decimal));
        table.Columns.Add("ImportRowNumber", typeof(int));
        table.Columns.Add("Notes", typeof(string));
        table.Columns.Add("SourceLineId", typeof(int));

        // Numbered from the position in the list, not from what the client sent — one authority.
        var lineNumber = 1;
        foreach (var line in lines)
        {
            table.Rows.Add(
                lineNumber++,
                line.ItemId,
                line.ItemUnitId,
                warehouseId,
                line.ExpiryDate is { } expiry ? expiry.ToDateTime(TimeOnly.MinValue) : DBNull.Value,
                line.Quantity,
                (object?)line.UnitPrice ?? DBNull.Value,
                (object?)line.DiscountPercent ?? DBNull.Value,
                (object?)line.ImportRowNumber ?? DBNull.Value,
                (object?)line.Notes ?? DBNull.Value,
                (object?)line.SourceLineId ?? DBNull.Value);
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

    private static string ResolveSortColumn(string? sortBy)
        => SortColumns.FirstOrDefault(c => string.Equals(c, sortBy, StringComparison.OrdinalIgnoreCase))
           ?? "DocumentDate";
}
