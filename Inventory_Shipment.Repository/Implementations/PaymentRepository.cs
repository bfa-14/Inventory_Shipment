using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class PaymentRepository : IPaymentRepository
{
    private const string LineTypeName = "purchase.tvp_PaymentLine";
    private const string AllocationTypeName = "purchase.tvp_PaymentAllocation";

    /// <summary>The columns the search procedure will sort by; anything else falls back to the date.</summary>
    private static readonly string[] SortColumns = ["PaymentNumber", "PaymentDate", "PayeeName", "Status", "AmountBase", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public PaymentRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// THE ROW, NOT THE DTO. Status is a TINYINT in the database and a word in the DTO, and Dapper will
    /// not turn one into the other: it would leave the default and say nothing. A private row with the
    /// code, mapped by hand, is how a Posted payment stays Posted.
    /// </summary>
    private sealed class ListRow
    {
        public int Id { get; init; }
        public string? PaymentNumber { get; init; }
        public DateTime PaymentDate { get; init; }
        public int PayeeId { get; init; }
        public string PayeeCode { get; init; } = string.Empty;
        public string PayeeName { get; init; } = string.Empty;
        public int BranchId { get; init; }
        public string BranchName { get; init; } = string.Empty;
        public byte PaymentType { get; init; }
        public int CurrencyId { get; init; }
        public string CurrencyCode { get; init; } = string.Empty;
        public int DecimalPlaces { get; init; }
        public decimal Amount { get; init; }
        public decimal ExchangeRate { get; init; }
        public decimal AmountBase { get; init; }
        public string? Reference { get; init; }
        public byte Status { get; init; }
        public string? Methods { get; init; }
        public decimal AllocatedAmount { get; init; }
        public decimal UnappliedAmount { get; init; }
        public int DocumentCount { get; init; }
        public DateTime? PostedAtUtc { get; init; }
        public string? PostedByName { get; init; }
        public DateTime? ReversedAtUtc { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public string? CreatedByName { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public PaymentListDto ToDto() => new()
        {
            Id = Id,
            PaymentNumber = PaymentNumber,
            PaymentDate = PaymentDate,
            PayeeId = PayeeId,
            PayeeCode = PayeeCode,
            PayeeName = PayeeName,
            BranchId = BranchId,
            BranchName = BranchName,
            PaymentType = PaymentType,
            CurrencyId = CurrencyId,
            CurrencyCode = CurrencyCode,
            DecimalPlaces = DecimalPlaces,
            Amount = Amount,
            ExchangeRate = ExchangeRate,
            AmountBase = AmountBase,
            Reference = Reference,
            Status = SupplierPaymentStatus.ToName(Status),
            Methods = Methods,
            AllocatedAmount = AllocatedAmount,
            UnappliedAmount = UnappliedAmount,
            DocumentCount = DocumentCount,
            PostedAtUtc = PostedAtUtc,
            PostedByName = PostedByName,
            ReversedAtUtc = ReversedAtUtc,
            CreatedAtUtc = CreatedAtUtc,
            CreatedByName = CreatedByName,
            UpdatedAtUtc = UpdatedAtUtc,
            RowVersion = RowVersion,
        };
    }

    public async Task<(IReadOnlyList<PaymentListDto> Items, int TotalCount)> SearchAsync(
        PaymentQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.PayeeId,
            query.BranchId,
            Status = SupplierPaymentStatus.ToCode(query.Status),
            query.PaymentType,
            query.CurrencyId,
            DateFrom = query.DateFrom?.ToDateTime(TimeOnly.MinValue),
            DateTo = query.DateTo?.ToDateTime(TimeOnly.MinValue),
            SortColumn = SortColumns.FirstOrDefault(c => string.Equals(c, query.SortBy, StringComparison.OrdinalIgnoreCase)) ?? "PaymentDate",
            SortDirection = string.Equals(query.SortDir, "asc", StringComparison.OrdinalIgnoreCase) ? "ASC" : "DESC",
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        var rows = (await connection.QueryAsync<ListRow>(new CommandDefinition(
            "purchase.usp_Payment_Search", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();

        return (rows.Select(r => r.ToDto()).ToList(), rows.Count > 0 ? rows[0].TotalCount : 0);
    }

    private sealed class HeaderRow
    {
        public int Id { get; init; }
        public string? PaymentNumber { get; init; }
        public DateTime PaymentDate { get; init; }
        public int PayeeId { get; init; }
        public string PayeeCode { get; init; } = string.Empty;
        public string PayeeName { get; init; } = string.Empty;
        public string? PayeeAddress { get; init; }
        public int BranchId { get; init; }
        public string BranchCode { get; init; } = string.Empty;
        public string BranchName { get; init; } = string.Empty;
        public byte PaymentType { get; init; }
        public int CurrencyId { get; init; }
        public string CurrencyCode { get; init; } = string.Empty;
        public string CurrencyName { get; init; } = string.Empty;
        public string? CurrencySymbol { get; init; }
        public int DecimalPlaces { get; init; }
        public bool IsBaseCurrency { get; init; }
        public decimal Amount { get; init; }
        public decimal ExchangeRate { get; init; }
        public decimal AmountBase { get; init; }
        public string? BaseCurrencyCode { get; init; }
        public string? Reference { get; init; }
        public string? Notes { get; init; }
        public byte Status { get; init; }
        public decimal LinesTotal { get; init; }
        public decimal AllocatedTotal { get; init; }
        public decimal UnappliedAmount { get; init; }
        public string? AllocationKind { get; init; }
        public DateTime? PostedAtUtc { get; init; }
        public int? PostedBy { get; init; }
        public string? PostedByName { get; init; }
        public DateTime? ReversedAtUtc { get; init; }
        public int? ReversedBy { get; init; }
        public string? ReversedByName { get; init; }
        public string? ReverseReason { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public int? CreatedBy { get; init; }
        public string? CreatedByName { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public int? UpdatedBy { get; init; }
        public string? UpdatedByName { get; init; }
        public byte[] RowVersion { get; init; } = [];
    }

    /// <summary>The line's number is a column called LineNumber and a property called LineNo, as on receipts.</summary>
    private sealed class LineRow
    {
        public int Id { get; init; }
        public int LineNumber { get; init; }
        public int PaymentMethodId { get; init; }
        public string MethodCode { get; init; } = string.Empty;
        public string MethodName { get; init; } = string.Empty;
        public bool IsCheque { get; init; }
        public int CurrencyId { get; init; }
        public string CurrencyCode { get; init; } = string.Empty;
        public int DecimalPlaces { get; init; }
        public decimal Amount { get; init; }
        public decimal RateToPayment { get; init; }
        public decimal AmountPaymentCurrency { get; init; }
        public decimal AmountBase { get; init; }
        public int CashBankAccountId { get; init; }
        public string AccountCode { get; init; } = string.Empty;
        public string AccountName { get; init; } = string.Empty;
        public string? Reference { get; init; }
        public string? ChequeNo { get; init; }
        public DateTime? ChequeDate { get; init; }
        public DateTime? ChequeDueDate { get; init; }
        public byte? ClearanceStatus { get; init; }
        public string? ClearanceStatusName { get; init; }
        public DateTime? ClearanceUpdatedAtUtc { get; init; }
        public string? ClearanceUpdatedByName { get; init; }

        public PaymentLineDto ToDto() => new()
        {
            Id = Id,
            LineNo = LineNumber,
            PaymentMethodId = PaymentMethodId,
            MethodCode = MethodCode,
            MethodName = MethodName,
            IsCheque = IsCheque,
            CurrencyId = CurrencyId,
            CurrencyCode = CurrencyCode,
            DecimalPlaces = DecimalPlaces,
            Amount = Amount,
            RateToPayment = RateToPayment,
            AmountPaymentCurrency = AmountPaymentCurrency,
            AmountBase = AmountBase,
            CashBankAccountId = CashBankAccountId,
            AccountCode = AccountCode,
            AccountName = AccountName,
            Reference = Reference,
            ChequeNo = ChequeNo,
            ChequeDate = ChequeDate,
            ChequeDueDate = ChequeDueDate,
            ClearanceStatus = ClearanceStatus,
            ClearanceStatusName = ClearanceStatusName,
            ClearanceUpdatedAtUtc = ClearanceUpdatedAtUtc,
            ClearanceUpdatedByName = ClearanceUpdatedByName,
        };
    }

    public async Task<PaymentDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "purchase.usp_Payment_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var header = await multi.ReadSingleOrDefaultAsync<HeaderRow>();
        if (header is null)
        {
            return null;
        }

        var lines = (await multi.ReadAsync<LineRow>()).AsList();
        var allocations = (await multi.ReadAsync<PaymentAllocationDto>()).AsList();
        var files = (await multi.ReadAsync<PaymentFileDto>()).AsList();
        var audit = (await multi.ReadAsync<PaymentAuditDto>()).AsList();

        return new PaymentDto
        {
            Id = header.Id,
            PaymentNumber = header.PaymentNumber,
            PaymentDate = header.PaymentDate,
            PayeeId = header.PayeeId,
            PayeeCode = header.PayeeCode,
            PayeeName = header.PayeeName,
            PayeeAddress = header.PayeeAddress,
            BranchId = header.BranchId,
            BranchCode = header.BranchCode,
            BranchName = header.BranchName,
            PaymentType = header.PaymentType,
            CurrencyId = header.CurrencyId,
            CurrencyCode = header.CurrencyCode,
            CurrencyName = header.CurrencyName,
            CurrencySymbol = header.CurrencySymbol,
            DecimalPlaces = header.DecimalPlaces,
            IsBaseCurrency = header.IsBaseCurrency,
            Amount = header.Amount,
            ExchangeRate = header.ExchangeRate,
            AmountBase = header.AmountBase,
            BaseCurrencyCode = header.BaseCurrencyCode,
            Reference = header.Reference,
            Notes = header.Notes,
            Status = SupplierPaymentStatus.ToName(header.Status),
            LinesTotal = header.LinesTotal,
            AllocatedTotal = header.AllocatedTotal,
            UnappliedAmount = header.UnappliedAmount,
            AllocationKind = header.AllocationKind,
            PostedAtUtc = header.PostedAtUtc,
            PostedBy = header.PostedBy,
            PostedByName = header.PostedByName,
            ReversedAtUtc = header.ReversedAtUtc,
            ReversedBy = header.ReversedBy,
            ReversedByName = header.ReversedByName,
            ReverseReason = header.ReverseReason,
            CreatedAtUtc = header.CreatedAtUtc,
            CreatedBy = header.CreatedBy,
            CreatedByName = header.CreatedByName,
            UpdatedAtUtc = header.UpdatedAtUtc,
            UpdatedBy = header.UpdatedBy,
            UpdatedByName = header.UpdatedByName,
            RowVersion = header.RowVersion,
            Lines = lines.Select(l => l.ToDto()).ToList(),
            Allocations = allocations,
            Files = files,
            Audit = audit,
        };
    }

    public async Task<IReadOnlyList<OpenPayableDocumentDto>> OpenDocumentsAsync(
        int payeeId, string documentKind, int? paymentCurrencyId, decimal? paymentRate, DateOnly? asOfDate,
        CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<OpenPayableDocumentDto>(new CommandDefinition(
                "purchase.usp_Payment_OpenDocuments",
                new
                {
                    PayeeId = payeeId,
                    DocumentKind = documentKind,
                    PaymentCurrencyId = paymentCurrencyId,
                    PaymentRate = paymentRate,
                    AsOfDate = asOfDate?.ToDateTime(TimeOnly.MinValue),
                },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            return rows.AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<PaymentRateDto?> RateToPaymentAsync(
        int fromCurrencyId, int paymentCurrencyId, decimal? paymentRate, DateOnly? asOfDate, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<PaymentRateDto>(new CommandDefinition(
            "purchase.usp_Payment_RateToPayment",
            new
            {
                FromCurrencyId = fromCurrencyId,
                PaymentCurrencyId = paymentCurrencyId,
                PaymentRate = paymentRate,
                AsOfDate = asOfDate?.ToDateTime(TimeOnly.MinValue),
            },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<int> SaveAsync(SavePaymentRequest request, int? id, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@PaymentDate", request.PaymentDate.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@PayeeId", request.PayeeId, DbType.Int32);
        parameters.Add("@BranchId", request.BranchId, DbType.Int32);
        parameters.Add("@PaymentType", request.PaymentType, DbType.Byte);
        parameters.Add("@CurrencyId", request.CurrencyId, DbType.Int32);
        parameters.Add("@Amount", request.Amount, DbType.Decimal, precision: 18, scale: 2);
        parameters.Add("@ExchangeRate", request.ExchangeRate, DbType.Decimal, precision: 18, scale: 6);
        parameters.Add("@Reference", request.Reference, DbType.String, size: 100);
        parameters.Add("@Notes", request.Notes, DbType.String, size: 500);
        parameters.Add("@Lines", ToLineTable(request.Lines).AsTableValuedParameter(LineTypeName));
        parameters.Add("@Allocations", ToAllocationTable(request.Allocations).AsTableValuedParameter(AllocationTypeName));
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await ExecuteAsync("purchase.usp_Payment_Save", parameters, cancellationToken);
        return parameters.Get<int>("@NewId");
    }

    public Task PostAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_Payment_Post", new { Id = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task ReverseAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_Payment_Reverse", new { Id = id, Reason = reason, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_Payment_Delete", new { Id = id, UserId = userId }, cancellationToken);

    public Task AllocateAsync(
        int id, IReadOnlyList<SavePaymentAllocationRequest> allocations, byte[]? rowVersion, int userId,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@PaymentId", id, DbType.Int32);
        parameters.Add("@Allocations", ToAllocationTable(allocations).AsTableValuedParameter(AllocationTypeName));
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        return ExecuteAsync("purchase.usp_Payment_Allocate", parameters, cancellationToken);
    }

    public Task DeallocateAsync(int allocationId, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_Payment_Deallocate", new { AllocationId = allocationId, UserId = userId }, cancellationToken);

    public Task SetChequeStatusAsync(int lineId, byte clearanceStatus, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_Payment_SetChequeStatus",
            new { LineId = lineId, ClearanceStatus = clearanceStatus, UserId = userId }, cancellationToken);

    /* ── files ────────────────────────────────────────────────────────────────────────────────── */

    public async Task<int> AddFileAsync(
        int paymentId, int? attachmentTypeId, string? note, string fileName, string contentType, byte[] content, int userId,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@PaymentId", paymentId, DbType.Int32);
        parameters.Add("@AttachmentTypeId", attachmentTypeId, DbType.Int32);
        parameters.Add("@Note", note, DbType.String, size: 300);
        parameters.Add("@FileName", fileName, DbType.String, size: 255);
        parameters.Add("@ContentType", contentType, DbType.String, size: 100);
        parameters.Add("@SizeBytes", content.Length, DbType.Int32);
        parameters.Add("@Content", content, DbType.Binary, size: -1);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await ExecuteAsync("purchase.usp_PaymentFile_Add", parameters, cancellationToken);
        return parameters.Get<int>("@NewId");
    }

    public async Task<PaymentFileContent?> GetFileAsync(int paymentId, int fileId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<PaymentFileContent>(new CommandDefinition(
            "purchase.usp_PaymentFile_Get", new { PaymentId = paymentId, FileId = fileId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    public Task DeleteFileAsync(int paymentId, int fileId, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_PaymentFile_Delete", new { PaymentId = paymentId, FileId = fileId, UserId = userId }, cancellationToken);

    /* ── plumbing ─────────────────────────────────────────────────────────────────────────────── */

    private async Task ExecuteAsync(string procedure, object parameters, CancellationToken cancellationToken)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                procedure, parameters, commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>
    /// The lines as a <see cref="DataTable"/> shaped like purchase.tvp_PaymentLine.
    ///
    /// COLUMN ORDER IS THE TYPE'S ORDER AND IS LOAD-BEARING: a table-valued parameter is sent positionally.
    /// Types are declared, not inferred, because a column that is null on every row infers as string and
    /// the server refuses the batch.
    /// </summary>
    private static DataTable ToLineTable(IReadOnlyList<SavePaymentLineRequest> lines)
    {
        var table = new DataTable();
        table.Columns.Add("LineNumber", typeof(int));
        table.Columns.Add("PaymentMethodId", typeof(int));
        table.Columns.Add("CurrencyId", typeof(int));
        table.Columns.Add("Amount", typeof(decimal));
        table.Columns.Add("RateToPayment", typeof(decimal));
        table.Columns.Add("CashBankAccountId", typeof(int));
        table.Columns.Add("Reference", typeof(string));
        table.Columns.Add("ChequeNo", typeof(string));
        table.Columns.Add("ChequeDate", typeof(DateTime));
        table.Columns.Add("ChequeDueDate", typeof(DateTime));

        // Numbered from the position in the list, not from what the client sent - one authority.
        var lineNumber = 1;
        foreach (var line in lines)
        {
            table.Rows.Add(
                lineNumber++,
                line.PaymentMethodId,
                line.CurrencyId,
                line.Amount,
                (object?)line.RateToPayment ?? DBNull.Value,
                line.CashBankAccountId,
                (object?)line.Reference ?? DBNull.Value,
                (object?)line.ChequeNo ?? DBNull.Value,
                (object?)line.ChequeDate?.ToDateTime(TimeOnly.MinValue) ?? DBNull.Value,
                (object?)line.ChequeDueDate?.ToDateTime(TimeOnly.MinValue) ?? DBNull.Value);
        }

        return table;
    }

    /// <summary>The allocations shaped like purchase.tvp_PaymentAllocation (kind, document, amount in ITS currency, rate).</summary>
    private static DataTable ToAllocationTable(IReadOnlyList<SavePaymentAllocationRequest> allocations)
    {
        var table = new DataTable();
        table.Columns.Add("DocumentKind", typeof(string));
        table.Columns.Add("DocumentId", typeof(int));
        table.Columns.Add("Amount", typeof(decimal));
        table.Columns.Add("RateToPayment", typeof(decimal));

        foreach (var allocation in allocations)
        {
            table.Rows.Add(
                allocation.DocumentKind.Trim().ToUpperInvariant(),
                allocation.DocumentId,
                allocation.Amount,
                (object?)allocation.RateToPayment ?? DBNull.Value);
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
