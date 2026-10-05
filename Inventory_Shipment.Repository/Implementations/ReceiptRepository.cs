using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Receipts;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class ReceiptRepository : IReceiptRepository
{
    private const string LineTypeName = "sales.tvp_ReceiptLine";
    private const string AllocationTypeName = "sales.tvp_ReceiptAllocation";

    /// <summary>The columns the search procedure will sort by; anything else falls back to the date.</summary>
    private static readonly string[] SortColumns = ["ReceiptNumber", "ReceiptDate", "ClientName", "Status", "AmountBase", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public ReceiptRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// THE ROW, NOT THE DTO. Status is a TINYINT in the database and a word in the DTO, and Dapper
    /// will not turn one into the other: it would leave the property at its default and say nothing.
    /// A private row with the code, mapped by hand, is how a Posted receipt stays Posted.
    /// </summary>
    private sealed class ListRow
    {
        public int Id { get; init; }
        public string? ReceiptNumber { get; init; }
        public DateTime ReceiptDate { get; init; }
        public int ClientId { get; init; }
        public string ClientCode { get; init; } = string.Empty;
        public string ClientName { get; init; } = string.Empty;
        public int BranchId { get; init; }
        public string BranchName { get; init; } = string.Empty;
        public byte PaymentType { get; init; }
        public int CurrencyId { get; init; }
        public string CurrencyCode { get; init; } = string.Empty;
        public int DecimalPlaces { get; init; }
        public decimal Amount { get; init; }
        public decimal ExchangeRate { get; init; }
        public decimal AmountBase { get; init; }
        public byte Status { get; init; }
        public int? SourceSalesDocumentId { get; init; }
        public string? SourceInvoiceNumber { get; init; }
        public decimal AllocatedBase { get; init; }
        public decimal UnappliedBase { get; init; }
        public DateTime? PostedAtUtc { get; init; }
        public string? PostedByName { get; init; }
        public DateTime? ReversedAtUtc { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public string? CreatedByName { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public ReceiptListDto ToDto() => new()
        {
            Id = Id,
            ReceiptNumber = ReceiptNumber,
            ReceiptDate = ReceiptDate,
            ClientId = ClientId,
            ClientCode = ClientCode,
            ClientName = ClientName,
            BranchId = BranchId,
            BranchName = BranchName,
            PaymentType = PaymentType,
            CurrencyId = CurrencyId,
            CurrencyCode = CurrencyCode,
            DecimalPlaces = DecimalPlaces,
            Amount = Amount,
            ExchangeRate = ExchangeRate,
            AmountBase = AmountBase,
            Status = ReceiptStatus.ToName(Status),
            SourceSalesDocumentId = SourceSalesDocumentId,
            SourceInvoiceNumber = SourceInvoiceNumber,
            AllocatedBase = AllocatedBase,
            UnappliedBase = UnappliedBase,
            PostedAtUtc = PostedAtUtc,
            PostedByName = PostedByName,
            ReversedAtUtc = ReversedAtUtc,
            CreatedAtUtc = CreatedAtUtc,
            CreatedByName = CreatedByName,
            UpdatedAtUtc = UpdatedAtUtc,
            RowVersion = RowVersion,
        };
    }

    public async Task<(IReadOnlyList<ReceiptListDto> Items, int TotalCount)> SearchAsync(
        ReceiptQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.ClientId,
            query.BranchId,
            Status = ReceiptStatus.ToCode(query.Status),
            query.PaymentType,
            query.CurrencyId,
            DateFrom = query.DateFrom?.ToDateTime(TimeOnly.MinValue),
            DateTo = query.DateTo?.ToDateTime(TimeOnly.MinValue),
            SortColumn = SortColumns.FirstOrDefault(c => string.Equals(c, query.SortBy, StringComparison.OrdinalIgnoreCase)) ?? "ReceiptDate",
            SortDirection = string.Equals(query.SortDir, "asc", StringComparison.OrdinalIgnoreCase) ? "ASC" : "DESC",
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        var rows = (await connection.QueryAsync<ListRow>(new CommandDefinition(
            "sales.usp_Receipt_Search", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();

        return (rows.Select(r => r.ToDto()).ToList(), rows.Count > 0 ? rows[0].TotalCount : 0);
    }

    private sealed class HeaderRow
    {
        public int Id { get; init; }
        public string? ReceiptNumber { get; init; }
        public DateTime ReceiptDate { get; init; }
        public int ClientId { get; init; }
        public string ClientCode { get; init; } = string.Empty;
        public string ClientName { get; init; } = string.Empty;
        public string? ClientAddress { get; init; }
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
        public string? Notes { get; init; }
        public byte Status { get; init; }
        public int? SourceSalesDocumentId { get; init; }
        public string? SourceInvoiceNumber { get; init; }
        public decimal LinesBase { get; init; }
        public decimal AllocatedBase { get; init; }
        public decimal UnappliedBase { get; init; }
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

    /// <summary>The line's number is a column called LineNumber and a property called LineNo, as on the invoices.</summary>
    private sealed class LineRow
    {
        public int Id { get; init; }
        public int LineNumber { get; init; }
        public int PaymentMethodId { get; init; }
        public string MethodCode { get; init; } = string.Empty;
        public string MethodName { get; init; } = string.Empty;
        public int CurrencyId { get; init; }
        public string CurrencyCode { get; init; } = string.Empty;
        public int DecimalPlaces { get; init; }
        public decimal Amount { get; init; }
        public decimal ExchangeRate { get; init; }
        public decimal AmountBase { get; init; }
        public int CashBankAccountId { get; init; }
        public string AccountCode { get; init; } = string.Empty;
        public string AccountName { get; init; } = string.Empty;
        public string? Reference { get; init; }

        public ReceiptLineDto ToDto() => new()
        {
            Id = Id,
            LineNo = LineNumber,
            PaymentMethodId = PaymentMethodId,
            MethodCode = MethodCode,
            MethodName = MethodName,
            CurrencyId = CurrencyId,
            CurrencyCode = CurrencyCode,
            DecimalPlaces = DecimalPlaces,
            Amount = Amount,
            ExchangeRate = ExchangeRate,
            AmountBase = AmountBase,
            CashBankAccountId = CashBankAccountId,
            AccountCode = AccountCode,
            AccountName = AccountName,
            Reference = Reference,
        };
    }

    public async Task<ReceiptDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "sales.usp_Receipt_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var header = await multi.ReadSingleOrDefaultAsync<HeaderRow>();
        if (header is null)
        {
            return null;
        }

        var lines = (await multi.ReadAsync<LineRow>()).AsList();
        var allocations = (await multi.ReadAsync<ReceiptAllocationDto>()).AsList();
        var files = (await multi.ReadAsync<ReceiptFileDto>()).AsList();
        var audit = (await multi.ReadAsync<ReceiptAuditDto>()).AsList();

        return new ReceiptDto
        {
            Id = header.Id,
            ReceiptNumber = header.ReceiptNumber,
            ReceiptDate = header.ReceiptDate,
            ClientId = header.ClientId,
            ClientCode = header.ClientCode,
            ClientName = header.ClientName,
            ClientAddress = header.ClientAddress,
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
            Notes = header.Notes,
            Status = ReceiptStatus.ToName(header.Status),
            SourceSalesDocumentId = header.SourceSalesDocumentId,
            SourceInvoiceNumber = header.SourceInvoiceNumber,
            LinesBase = header.LinesBase,
            AllocatedBase = header.AllocatedBase,
            UnappliedBase = header.UnappliedBase,
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

    public async Task<IReadOnlyList<OpenInvoiceDto>> OpenInvoicesAsync(int clientId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<OpenInvoiceDto>(new CommandDefinition(
            "sales.usp_Receipt_OpenInvoices", new { ClientId = clientId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        return rows.AsList();
    }

    public async Task<CustomerStatementDto> StatementAsync(int clientId, DateOnly? from, DateOnly? to, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
                "sales.usp_Customer_Statement",
                new { ClientId = clientId, DateFrom = from?.ToDateTime(TimeOnly.MinValue), DateTo = to?.ToDateTime(TimeOnly.MinValue) },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var head = await grid.ReadSingleAsync<StatementHeadRow>();
            var entries = (await grid.ReadAsync<CustomerStatementEntryDto>()).AsList();
            return new CustomerStatementDto
            {
                ClientId = head.ClientId,
                ClientCode = head.ClientCode,
                ClientName = head.ClientName,
                BaseCurrencyCode = head.BaseCurrencyCode,
                OpeningBalance = head.OpeningBalance,
                Entries = entries,
            };
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    private sealed class StatementHeadRow
    {
        public int ClientId { get; init; }
        public string ClientCode { get; init; } = string.Empty;
        public string ClientName { get; init; } = string.Empty;
        public string? BaseCurrencyCode { get; init; }
        public decimal OpeningBalance { get; init; }
    }

    public async Task<ReceiptRateDto?> ResolveRateAsync(int currencyId, DateOnly? asOfDate, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<ReceiptRateDto>(new CommandDefinition(
            "sales.usp_Receipt_ResolveRate",
            new { CurrencyId = currencyId, AsOfDate = asOfDate?.ToDateTime(TimeOnly.MinValue) },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<int> SaveAsync(SaveReceiptRequest request, int? id, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@ReceiptDate", request.ReceiptDate.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@ClientId", request.ClientId, DbType.Int32);
        parameters.Add("@BranchId", request.BranchId, DbType.Int32);
        parameters.Add("@PaymentType", request.PaymentType, DbType.Byte);
        parameters.Add("@CurrencyId", request.CurrencyId, DbType.Int32);
        parameters.Add("@Amount", request.Amount, DbType.Decimal, precision: 18, scale: 2);
        parameters.Add("@ExchangeRate", request.ExchangeRate, DbType.Decimal, precision: 18, scale: 6);
        parameters.Add("@Notes", request.Notes, DbType.String, size: 1000);
        parameters.Add("@Lines", ToLineTable(request.Lines).AsTableValuedParameter(LineTypeName));
        parameters.Add("@Allocations", ToAllocationTable(request.Allocations).AsTableValuedParameter(AllocationTypeName));
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await ExecuteAsync("sales.usp_Receipt_Save", parameters, cancellationToken);
        return parameters.Get<int>("@NewId");
    }

    public Task PostAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("sales.usp_Receipt_Post", new { Id = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task ReverseAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("sales.usp_Receipt_Reverse", new { Id = id, Reason = reason, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("sales.usp_Receipt_Delete", new { Id = id, UserId = userId }, cancellationToken);

    public Task AllocateAsync(
        int id, IReadOnlyList<SaveReceiptAllocationRequest> allocations, byte[]? rowVersion, int userId,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@ReceiptId", id, DbType.Int32);
        parameters.Add("@Allocations", ToAllocationTable(allocations).AsTableValuedParameter(AllocationTypeName));
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        return ExecuteAsync("sales.usp_Receipt_Allocate", parameters, cancellationToken);
    }

    public Task DeallocateAsync(int allocationId, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("sales.usp_Receipt_Deallocate", new { AllocationId = allocationId, UserId = userId }, cancellationToken);

    /* ── files ────────────────────────────────────────────────────────────────────────────────── */

    public async Task<int> AddFileAsync(
        int receiptId, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@ReceiptId", receiptId, DbType.Int32);
        parameters.Add("@AttachmentTypeId", fields.AttachmentTypeId, DbType.Int32);
        parameters.Add("@Note", fields.Note, DbType.String, size: 500);
        parameters.Add("@DocumentDate", fields.DocumentDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@FileName", fileName, DbType.String, size: 255);
        parameters.Add("@ContentType", contentType, DbType.String, size: 100);
        parameters.Add("@SizeBytes", content.Length, DbType.Int32);
        parameters.Add("@Content", content, DbType.Binary, size: -1);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await ExecuteAsync("sales.usp_ReceiptFile_Add", parameters, cancellationToken);
        return parameters.Get<int>("@NewId");
    }

    public async Task<IReadOnlyList<DocumentFileDto>> ListFilesAsync(
        int receiptId, int? attachmentTypeId = null, int? fileId = null, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<DocumentFileDto>(new CommandDefinition(
            "sales.usp_ReceiptFile_List", new { ReceiptId = receiptId, AttachmentTypeId = attachmentTypeId, FileId = fileId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return rows.AsList();
    }

    public async Task<DocumentFileDto?> UpdateFileAsync(
        int receiptId, int fileId, DocumentFileFields fields, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            ReceiptId = receiptId,
            FileId = fileId,
            fields.AttachmentTypeId,
            DocumentDate = fields.DocumentDate?.ToDateTime(TimeOnly.MinValue),
            fields.Note,
            UserId = userId,
        };

        await using var connection = _connectionFactory.Create();
        try
        {
            return await connection.QuerySingleOrDefaultAsync<DocumentFileDto>(new CommandDefinition(
                "sales.usp_ReceiptFile_Update", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<ReceiptFileContent?> GetFileAsync(int receiptId, int fileId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<ReceiptFileContent>(new CommandDefinition(
            "sales.usp_ReceiptFile_Get", new { ReceiptId = receiptId, FileId = fileId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    public Task DeleteFileAsync(int receiptId, int fileId, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("sales.usp_ReceiptFile_Delete", new { ReceiptId = receiptId, FileId = fileId, UserId = userId }, cancellationToken);

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
    /// The lines as a <see cref="DataTable"/> shaped like sales.tvp_ReceiptLine.
    ///
    /// COLUMN ORDER IS THE TYPE'S ORDER AND IS LOAD-BEARING: a table-valued parameter is sent
    /// positionally, so two columns swapped here would put a currency id where an amount belongs and
    /// the server would accept it. Types are declared, not inferred, because a column that is null on
    /// every row (the rate, usually) infers as string and the server refuses the batch.
    /// </summary>
    private static DataTable ToLineTable(IReadOnlyList<SaveReceiptLineRequest> lines)
    {
        var table = new DataTable();
        table.Columns.Add("LineNumber", typeof(int));
        table.Columns.Add("PaymentMethodId", typeof(int));
        table.Columns.Add("CurrencyId", typeof(int));
        table.Columns.Add("Amount", typeof(decimal));
        table.Columns.Add("ExchangeRate", typeof(decimal));
        table.Columns.Add("CashBankAccountId", typeof(int));
        table.Columns.Add("Reference", typeof(string));

        // Numbered from the position in the list, not from what the client sent - one authority.
        var lineNumber = 1;
        foreach (var line in lines)
        {
            table.Rows.Add(
                lineNumber++,
                line.PaymentMethodId,
                line.CurrencyId,
                line.Amount,
                (object?)line.ExchangeRate ?? DBNull.Value,
                line.CashBankAccountId,
                (object?)line.Reference ?? DBNull.Value);
        }

        return table;
    }

    /// <summary>The allocations as a <see cref="DataTable"/> shaped like sales.tvp_ReceiptAllocation (invoice, amount in ITS currency).</summary>
    private static DataTable ToAllocationTable(IReadOnlyList<SaveReceiptAllocationRequest> allocations)
    {
        var table = new DataTable();
        table.Columns.Add("SalesDocumentId", typeof(int));
        table.Columns.Add("Amount", typeof(decimal));

        foreach (var allocation in allocations)
        {
            table.Rows.Add(allocation.SalesDocumentId, allocation.Amount);
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
