using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class SalesDocumentRepository : ISalesDocumentRepository
{
    /// <summary>Matched by TYPE NAME on the server; a wrong one fails with a message that never mentions the type.</summary>
    private const string LineTypeName = "sales.tvp_SalesDocumentLine";

    /// <summary>The columns the search procedure will sort by; anything else falls back to the document date.</summary>
    private static readonly string[] SortColumns =
        ["DocumentNumber", "DocumentDate", "ClientName", "Status", "TotalAmount", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public SalesDocumentRepository(ISqlConnectionFactory connectionFactory)
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
        public string? DocumentNumber { get; init; }
        public DateTime DocumentDate { get; init; }
        public DateTime? DueDate { get; init; }
        public int BranchId { get; init; }
        public string BranchName { get; init; } = string.Empty;
        public int WarehouseId { get; init; }
        public string WarehouseName { get; init; } = string.Empty;
        public int ClientId { get; init; }
        public string ClientCode { get; init; } = string.Empty;
        public string ClientName { get; init; } = string.Empty;
        public int? SalesmanId { get; init; }
        public string? SalesmanName { get; init; }
        public int PriceListId { get; init; }
        public string PriceListName { get; init; } = string.Empty;
        public string CurrencyCode { get; init; } = string.Empty;
        public string? CurrencySymbol { get; init; }
        public byte DecimalPlaces { get; init; }
        public decimal ExchangeRate { get; init; }
        public string? ReferenceNo { get; init; }
        public byte Status { get; init; }
        public int TotalItems { get; init; }
        public decimal TotalQuantity { get; init; }
        public decimal Subtotal { get; init; }
        public decimal TotalDiscount { get; init; }
        public decimal TotalAmount { get; init; }
        public decimal TotalAmountBase { get; init; }
        public decimal PaidAmount { get; init; }
        public decimal? OutstandingAmount { get; init; }
        public string? PaymentStatus { get; init; }
        public DateTime? PostedAtUtc { get; init; }
        public string? PostedByName { get; init; }
        public DateTime? CancelledAtUtc { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public string? CreatedByName { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public SalesInvoiceListDto ToDto() => new()
        {
            Id = Id,
            DocumentTypeCode = DocumentTypeCode,
            DocumentTypeName = DocumentTypeName,
            DocumentNumber = DocumentNumber,
            DocumentDate = DocumentDate,
            DueDate = DueDate,
            BranchId = BranchId,
            BranchName = BranchName,
            WarehouseId = WarehouseId,
            WarehouseName = WarehouseName,
            ClientId = ClientId,
            ClientCode = ClientCode,
            ClientName = ClientName,
            SalesmanId = SalesmanId,
            SalesmanName = SalesmanName,
            PriceListId = PriceListId,
            PriceListName = PriceListName,
            CurrencyCode = CurrencyCode,
            CurrencySymbol = CurrencySymbol,
            DecimalPlaces = DecimalPlaces,
            ExchangeRate = ExchangeRate,
            ReferenceNo = ReferenceNo,
            Status = StockDocumentStatus.From(Status),
            TotalItems = TotalItems,
            TotalQuantity = TotalQuantity,
            Subtotal = Subtotal,
            TotalDiscount = TotalDiscount,
            TotalAmount = TotalAmount,
            TotalAmountBase = TotalAmountBase,
            PaidAmount = PaidAmount,
            OutstandingAmount = OutstandingAmount,
            PaymentStatus = PaymentStatus,
            PostedAtUtc = PostedAtUtc,
            PostedByName = PostedByName,
            CancelledAtUtc = CancelledAtUtc,
            CreatedAtUtc = CreatedAtUtc,
            CreatedByName = CreatedByName,
            RowVersion = RowVersion,
        };
    }

    public async Task<(IReadOnlyList<SalesInvoiceListDto> Items, int TotalCount)> SearchAsync(
        SalesInvoiceQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            DocumentTypeCode = SalesDocumentTypes.Invoice,
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.BranchId,
            query.WarehouseId,
            query.ClientId,
            query.SalesmanId,
            Status = ToStatusCode(query.Status),
            DateFrom = query.DateFrom?.ToDateTime(TimeOnly.MinValue),
            DateTo = query.DateTo?.ToDateTime(TimeOnly.MinValue),
            PaymentStatus = string.IsNullOrWhiteSpace(query.PaymentStatus) ? null : query.PaymentStatus.Trim(),
            SortColumn = ResolveSortColumn(query.SortBy),
            SortDirection = string.Equals(query.SortDir, "asc", StringComparison.OrdinalIgnoreCase) ? "ASC" : "DESC",
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<ListRow>(new CommandDefinition(
                "sales.usp_SalesDocument_Search", parameters,
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
        public bool NumberOnPost { get; init; }
        public string? DocumentNumber { get; init; }
        public DateTime DocumentDate { get; init; }
        public DateTime? DueDate { get; init; }
        public int BranchId { get; init; }
        public string BranchCode { get; init; } = string.Empty;
        public string BranchName { get; init; } = string.Empty;
        public int WarehouseId { get; init; }
        public string WarehouseCode { get; init; } = string.Empty;
        public string WarehouseName { get; init; } = string.Empty;
        public int ClientId { get; init; }
        public string ClientCode { get; init; } = string.Empty;
        public string ClientName { get; init; } = string.Empty;
        public string? ClientPhone { get; init; }
        public string? ClientEmail { get; init; }
        public string? ClientAddress { get; init; }
        public int? SalesmanId { get; init; }
        public string? SalesmanCode { get; init; }
        public string? SalesmanName { get; init; }
        public int PriceListId { get; init; }
        public string PriceListCode { get; init; } = string.Empty;
        public string PriceListName { get; init; } = string.Empty;
        public int CurrencyId { get; init; }
        public string CurrencyCode { get; init; } = string.Empty;
        public string CurrencyName { get; init; } = string.Empty;
        public string? CurrencySymbol { get; init; }
        public byte DecimalPlaces { get; init; }
        public bool IsBaseCurrency { get; init; }
        public byte RateType { get; init; }
        public decimal ExchangeRate { get; init; }
        public string? BaseCurrencyCode { get; init; }
        public string? ReferenceNo { get; init; }
        public string? Notes { get; init; }
        public byte Status { get; init; }
        public int TotalItems { get; init; }
        public decimal TotalQuantity { get; init; }
        public decimal Subtotal { get; init; }
        public decimal TotalDiscount { get; init; }
        public decimal TotalAmount { get; init; }
        public decimal TotalAmountBase { get; init; }
        public decimal PaidAmount { get; init; }
        public decimal? OutstandingAmount { get; init; }
        public string? PaymentStatus { get; init; }
        public decimal? TotalCostBase { get; init; }
        public decimal? TotalGrossProfitBase { get; init; }
        public decimal? TotalGrossProfitPct { get; init; }
        public int? SourceDocumentId { get; init; }
        public string? SourceDocumentNumber { get; init; }
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
        public string? Specification { get; init; }
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
        public string PriceSource { get; init; } = PriceSources.PriceList;
        public decimal? UnitCostBase { get; init; }
        public decimal? FobCostAtSale { get; init; }
        public decimal? LastCostAtSale { get; init; }
        public decimal? NetSalesBase { get; init; }
        public decimal? CogsBase { get; init; }
        public decimal? GrossProfitBase { get; init; }
        public decimal? GrossProfitPct { get; init; }
        public decimal ReturnedQuantityBase { get; init; }
        public decimal RemainingBase { get; init; }
        public int? ImportRowNumber { get; init; }
        public string? Notes { get; init; }
        public decimal OnHandBase { get; init; }
        public decimal? SystemPrice { get; init; }
        public decimal? ItemAverageCost { get; init; }

        public SalesInvoiceLineDto ToDto() => new()
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
            Specification = Specification,
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
            PriceSource = PriceSource,
            UnitCostBase = UnitCostBase,
            FobCostAtSale = FobCostAtSale,
            LastCostAtSale = LastCostAtSale,
            NetSalesBase = NetSalesBase,
            CogsBase = CogsBase,
            GrossProfitBase = GrossProfitBase,
            GrossProfitPct = GrossProfitPct,
            ReturnedQuantityBase = ReturnedQuantityBase,
            RemainingBase = RemainingBase,
            ImportRowNumber = ImportRowNumber,
            Notes = Notes,
            OnHandBase = OnHandBase,
            SystemPrice = SystemPrice,
            ItemAverageCost = ItemAverageCost,
        };
    }

    public async Task<SalesInvoiceDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();

        // Four result sets in one round trip, so the header and the lines are from the same moment.
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "sales.usp_SalesDocument_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var header = await multi.ReadSingleOrDefaultAsync<HeaderRow>();
        if (header is null)
        {
            return null;
        }

        var lines = (await multi.ReadAsync<LineRow>()).AsList();
        var files = (await multi.ReadAsync<SalesInvoiceFileDto>()).AsList();
        var audit = (await multi.ReadAsync<SalesInvoiceAuditDto>()).AsList();

        return new SalesInvoiceDto
        {
            Id = header.Id,
            DocumentTypeId = header.DocumentTypeId,
            DocumentTypeCode = header.DocumentTypeCode,
            DocumentTypeName = header.DocumentTypeName,
            NumberOnPost = header.NumberOnPost,
            DocumentNumber = header.DocumentNumber,
            DocumentDate = header.DocumentDate,
            DueDate = header.DueDate,
            BranchId = header.BranchId,
            BranchCode = header.BranchCode,
            BranchName = header.BranchName,
            WarehouseId = header.WarehouseId,
            WarehouseCode = header.WarehouseCode,
            WarehouseName = header.WarehouseName,
            ClientId = header.ClientId,
            ClientCode = header.ClientCode,
            ClientName = header.ClientName,
            ClientPhone = header.ClientPhone,
            ClientEmail = header.ClientEmail,
            ClientAddress = header.ClientAddress,
            SalesmanId = header.SalesmanId,
            SalesmanCode = header.SalesmanCode,
            SalesmanName = header.SalesmanName,
            PriceListId = header.PriceListId,
            PriceListCode = header.PriceListCode,
            PriceListName = header.PriceListName,
            CurrencyId = header.CurrencyId,
            CurrencyCode = header.CurrencyCode,
            CurrencyName = header.CurrencyName,
            CurrencySymbol = header.CurrencySymbol,
            DecimalPlaces = header.DecimalPlaces,
            IsBaseCurrency = header.IsBaseCurrency,
            RateType = header.RateType,
            ExchangeRate = header.ExchangeRate,
            BaseCurrencyCode = header.BaseCurrencyCode,
            ReferenceNo = header.ReferenceNo,
            Notes = header.Notes,
            Status = StockDocumentStatus.From(header.Status),
            TotalItems = header.TotalItems,
            TotalQuantity = header.TotalQuantity,
            Subtotal = header.Subtotal,
            TotalDiscount = header.TotalDiscount,
            TotalAmount = header.TotalAmount,
            TotalAmountBase = header.TotalAmountBase,
            PaidAmount = header.PaidAmount,
            OutstandingAmount = header.OutstandingAmount,
            PaymentStatus = header.PaymentStatus,
            TotalCostBase = header.TotalCostBase,
            TotalGrossProfitBase = header.TotalGrossProfitBase,
            TotalGrossProfitPct = header.TotalGrossProfitPct,
            SourceDocumentId = header.SourceDocumentId,
            SourceDocumentNumber = header.SourceDocumentNumber,
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

    /// <summary>
    /// The specifications already used for one item on sales lines, newest first.
    ///
    /// THE SUGGESTIONS ARE HISTORY, not a master list: the column is free text, and this only saves
    /// somebody retyping what the last invoice for the same item said.
    /// </summary>
    public async Task<IReadOnlyList<string>> ItemSpecificationsAsync(
        int itemId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<string>(new CommandDefinition(
            "sales.usp_SalesDocument_ItemSpecifications", new { ItemId = itemId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        return rows.AsList();
    }

    public async Task<RateResolutionDto?> ResolveRateAsync(
        int priceListId, byte rateType, DateOnly? asOfDate, int? currencyId = null, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<RateResolutionDto>(new CommandDefinition(
            "sales.usp_SalesDocument_ResolveRate",
            new
            {
                PriceListId = priceListId,
                RateType = rateType,
                AsOfDate = asOfDate?.ToDateTime(TimeOnly.MinValue),
                CurrencyId = currencyId,
            },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<int> SaveAsync(
        SaveSalesInvoiceRequest request, int? id, bool allowPriceOverride, decimal maxDiscountPercent,
        int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@DocumentTypeCode", SalesDocumentTypes.Invoice, DbType.String, size: 20);
        parameters.Add("@DocumentDate", request.DocumentDate.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@DueDate", request.DueDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@BranchId", request.BranchId, DbType.Int32);
        parameters.Add("@WarehouseId", request.WarehouseId, DbType.Int32);
        parameters.Add("@ClientId", request.ClientId, DbType.Int32);
        parameters.Add("@SalesmanId", request.SalesmanId, DbType.Int32);
        parameters.Add("@PriceListId", request.PriceListId, DbType.Int32);
        parameters.Add("@CurrencyId", request.CurrencyId, DbType.Int32);
        parameters.Add("@RateType", request.RateType, DbType.Byte);
        parameters.Add("@ExchangeRate", request.ExchangeRate, DbType.Decimal);
        parameters.Add("@ReferenceNo", request.ReferenceNo, DbType.String, size: 100);
        parameters.Add("@Notes", request.Notes, DbType.String, size: 1000);
        parameters.Add("@Lines", ToLineTable(request.Lines).AsTableValuedParameter(LineTypeName));
        parameters.Add("@AllowPriceOverride", allowPriceOverride, DbType.Boolean);
        parameters.Add("@MaxDiscountPercent", maxDiscountPercent, DbType.Decimal);
        parameters.Add("@DraftReference", request.DraftReference, DbType.String, size: 50);
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "sales.usp_SalesDocument_Save", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return parameters.Get<int>("@NewId");
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public Task PostAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("sales.usp_SalesDocument_Post",
            new { Id = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("sales.usp_SalesDocument_Cancel",
            new { Id = id, Reason = reason, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("sales.usp_SalesDocument_Delete", new { Id = id, UserId = userId }, cancellationToken);

    /// <summary>
    /// A sales return draft from a posted invoice: what has not already come back, at the invoice's
    /// own prices and — this is the point — its ORIGINAL cost of sales, so returning goods reverses
    /// the margin that was booked rather than today's average.
    /// </summary>
    public async Task<int> CreateFromSourceAsync(
        int sourceId, DateOnly? documentDate, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@SourceId", sourceId, DbType.Int32);
        parameters.Add("@DocumentDate", documentDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        try
        {
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.ExecuteAsync(new CommandDefinition(
                    "sales.usp_SalesDocument_CreateFromSource", parameters,
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
        => ExecuteAsync("sales.usp_SalesDocumentFile_Delete", new { Id = fileId, UserId = userId }, cancellationToken);

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
                "sales.usp_SalesDocumentFile_Add", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return parameters.Get<int>("@NewId");
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<SalesDocumentFileContent?> GetFileAsync(int fileId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<SalesDocumentFileContent>(new CommandDefinition(
            "sales.usp_SalesDocumentFile_Get", new { Id = fileId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

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
    /// The lines as a <see cref="DataTable"/> shaped like sales.tvp_SalesDocumentLine.
    ///
    /// COLUMN ORDER IS THE TYPE'S ORDER AND IS LOAD-BEARING — a table-valued parameter is sent
    /// positionally. Kept in the same order as the CREATE TYPE; types declared, not inferred, because
    /// an all-null column infers as string and the server refuses the batch.
    /// </summary>
    private static DataTable ToLineTable(IReadOnlyList<SaveSalesInvoiceLineRequest> lines)
    {
        var table = new DataTable();
        table.Columns.Add("LineNumber", typeof(int));
        table.Columns.Add("ItemId", typeof(int));
        table.Columns.Add("ItemUnitId", typeof(int));
        table.Columns.Add("WarehouseId", typeof(int));
        table.Columns.Add("Specification", typeof(string));
        table.Columns.Add("ExpiryDate", typeof(DateTime));
        table.Columns.Add("Quantity", typeof(int));
        table.Columns.Add("UnitPrice", typeof(decimal));
        table.Columns.Add("DiscountPercent", typeof(decimal));
        table.Columns.Add("ImportRowNumber", typeof(int));
        table.Columns.Add("Notes", typeof(string));

        // Numbered from the position in the list, not from what the client sent — one authority.
        var lineNumber = 1;
        foreach (var line in lines)
        {
            table.Rows.Add(
                lineNumber++,
                line.ItemId,
                line.ItemUnitId,
                line.WarehouseId,
                (object?)line.Specification ?? DBNull.Value,
                line.ExpiryDate is { } expiry ? expiry.ToDateTime(TimeOnly.MinValue) : DBNull.Value,
                line.Quantity,
                (object?)line.UnitPrice ?? DBNull.Value,
                (object?)line.DiscountPercent ?? DBNull.Value,
                (object?)line.ImportRowNumber ?? DBNull.Value,
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

    private static byte? ToStatusCode(string? status) => status switch
    {
        // The list page may send the code itself (1 Draft, 2 Posted, 3 Cancelled) as well as the word.
        "1" => StockDocumentStatus.DraftCode,
        "2" => StockDocumentStatus.PostedCode,
        "3" => StockDocumentStatus.CancelledCode,
        StockDocumentStatus.Draft => StockDocumentStatus.DraftCode,
        StockDocumentStatus.Posted => StockDocumentStatus.PostedCode,
        StockDocumentStatus.Cancelled => StockDocumentStatus.CancelledCode,
        _ => null,
    };

    private static string ResolveSortColumn(string? sortBy)
        => SortColumns.FirstOrDefault(c => string.Equals(c, sortBy, StringComparison.OrdinalIgnoreCase))
           ?? "DocumentDate";
}
