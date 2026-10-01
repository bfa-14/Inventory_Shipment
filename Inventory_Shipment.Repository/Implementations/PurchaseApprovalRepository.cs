using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class PurchaseApprovalRepository : IPurchaseApprovalRepository
{
    private const string ApproverTypeName = "purchase.tvp_OrderApprover";

    private readonly ISqlConnectionFactory _connectionFactory;

    public PurchaseApprovalRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>usp_PurchaseOrder_ApprovalState's first row: the status as the procedure's number.</summary>
    private sealed class StateRow
    {
        public byte Status { get; init; }
        public bool NeedsApproval { get; init; }
        public bool RequireApproval { get; init; }
        public decimal ApprovalLimitBase { get; init; }
        public string? BaseCurrencyCode { get; init; }
        public decimal? TotalBase { get; init; }
        public bool AllowSelfApproval { get; init; }
        public bool UserCanApproveInApp { get; init; }
        public bool CanApproveDirect { get; init; }
        public int? RequestedBy { get; init; }
        public string? RequestedByName { get; init; }
        public DateTime? RequestedAtUtc { get; init; }
        public DateTime? LinksValidUntilUtc { get; init; }
        public DateTime? NextReminderAtUtc { get; init; }
        public string? LastRejectedByName { get; init; }
        public DateTime? LastRejectedAtUtc { get; init; }
        public string? LastRejectReason { get; init; }
        public string? SupplierEmail { get; init; }
        public DateTime? SentToSupplierAtUtc { get; init; }
        public bool SupplierNotEmailed { get; init; }
    }

    public async Task<IReadOnlyList<ApprovalLinkRow>> RequestApprovalAsync(
        int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
    {
        var rows = await QueryAsync<ApprovalLinkRow>("purchase.usp_PurchaseOrder_RequestApproval",
            new { Id = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);
        foreach (var row in rows)
        {
            row.PurchaseDocumentId = id;
        }

        return rows;
    }

    public async Task<IReadOnlyList<ApprovalLinkRow>> ResendAsync(
        int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
    {
        var rows = await QueryAsync<ApprovalLinkRow>("purchase.usp_PurchaseOrder_Resend",
            new { PurchaseDocumentId = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);
        foreach (var row in rows)
        {
            row.PurchaseDocumentId = id;
        }

        return rows;
    }

    public Task WithdrawAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_PurchaseOrder_Withdraw", new { Id = id, UserId = userId }, cancellationToken);

    public Task<ApprovalDecisionRow> DecideInAppAsync(
        int id, byte[]? rowVersion, bool approve, string? reason, int userId, CancellationToken cancellationToken = default)
        => SingleAsync<ApprovalDecisionRow>("purchase.usp_PurchaseOrder_DecideInApp",
            new { PurchaseDocumentId = id, RowVersion = rowVersion, Approve = approve, Reason = reason, UserId = userId }, cancellationToken);

    public Task<ApprovalDecisionRow> ApproveDirectAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => SingleAsync<ApprovalDecisionRow>("purchase.usp_PurchaseOrder_ApproveDirect",
            new { PurchaseDocumentId = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task<ApprovalDecisionRow> DecideByTokenAsync(string token, bool approve, string? note, CancellationToken cancellationToken = default)
        => SingleAsync<ApprovalDecisionRow>("purchase.usp_PurchaseOrder_Decide",
            new { Token = new DbString { Value = token, IsAnsi = true, Length = 64 }, Approve = approve, Note = note }, cancellationToken);

    public Task<ApprovalLinkInfo> GetByTokenAsync(string token, CancellationToken cancellationToken = default)
        => SingleAsync<ApprovalLinkInfo>("purchase.usp_PurchaseOrder_GetByToken",
            new { Token = new DbString { Value = token, IsAnsi = true, Length = 64 } }, cancellationToken);

    public Task<IReadOnlyList<ApprovalLinkRow>> DueRemindersAsync(int maxOrders, CancellationToken cancellationToken = default)
        => QueryAsync<ApprovalLinkRow>("purchase.usp_PurchaseOrder_DueReminders", new { MaxOrders = maxOrders }, cancellationToken);

    public async Task<(ApprovalStateDto State, IReadOnlyList<ApprovalApproverDto> Approvers)> GetStateAsync(
        int id, int userId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
                "purchase.usp_PurchaseOrder_ApprovalState", new { PurchaseDocumentId = id, UserId = userId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var row = await grid.ReadSingleAsync<StateRow>();
            var approvers = (await grid.ReadAsync<ApprovalApproverDto>()).AsList();
            var state = new ApprovalStateDto
            {
                Status = PurchaseDocumentStatus.From(row.Status),
                NeedsApproval = row.NeedsApproval,
                RequireApproval = row.RequireApproval,
                ApprovalLimitBase = row.ApprovalLimitBase,
                BaseCurrencyCode = row.BaseCurrencyCode,
                TotalBase = row.TotalBase ?? 0,
                AllowSelfApproval = row.AllowSelfApproval,
                UserCanApproveInApp = row.UserCanApproveInApp,
                CanApproveDirect = row.CanApproveDirect,
                RequestedBy = row.RequestedBy,
                RequestedByName = row.RequestedByName,
                RequestedAtUtc = row.RequestedAtUtc,
                LinksValidUntilUtc = row.LinksValidUntilUtc,
                NextReminderAtUtc = row.NextReminderAtUtc,
                LastRejectedByName = row.LastRejectedByName,
                LastRejectedAtUtc = row.LastRejectedAtUtc,
                LastRejectReason = row.LastRejectReason,
                SupplierEmail = row.SupplierEmail,
                SentToSupplierAtUtc = row.SentToSupplierAtUtc,
                SupplierNotEmailed = row.SupplierNotEmailed,
            };

            return (state, approvers);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public Task<IReadOnlyList<ApprovalEventDto>> GetHistoryAsync(int id, CancellationToken cancellationToken = default)
        => QueryAsync<ApprovalEventDto>("purchase.usp_PurchaseOrder_ApprovalHistory", new { PurchaseDocumentId = id }, cancellationToken);

    public Task<IReadOnlyList<PendingApprovalDto>> GetPendingForUserAsync(int userId, CancellationToken cancellationToken = default)
        => QueryAsync<PendingApprovalDto>("purchase.usp_PurchaseOrder_PendingForUser", new { UserId = userId }, cancellationToken);

    public Task LogSupplierEmailAsync(int id, bool sent, string? recipients, int? userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_PurchaseOrder_SupplierEmailLogged",
            new { PurchaseDocumentId = id, Sent = sent, Recipients = recipients, UserId = userId }, cancellationToken);

    public async Task<ApprovalSettingsDto> GetSettingsAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        await using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
            "purchase.usp_ApprovalSettings_Get", commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        return await ReadSettingsAsync(grid);
    }

    public async Task<ApprovalSettingsDto> SaveSettingsAsync(
        SaveApprovalSettingsRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
    {
        // Columns in the order of purchase.tvp_OrderApprover: UserId, CanApproveInApp, CanApproveByEmail.
        var approvers = new DataTable();
        approvers.Columns.Add("UserId", typeof(int));
        approvers.Columns.Add("CanApproveInApp", typeof(bool));
        approvers.Columns.Add("CanApproveByEmail", typeof(bool));
        foreach (var approver in request.Approvers.GroupBy(a => a.UserId).Select(g => g.Last()))
        {
            approvers.Rows.Add(approver.UserId, approver.CanApproveInApp, approver.CanApproveByEmail);
        }

        var parameters = new DynamicParameters();
        parameters.Add("@RequireApproval", request.RequireApproval);
        parameters.Add("@ApprovalLimitBase", request.ApprovalLimitBase);
        parameters.Add("@AllowSelfApproval", request.AllowSelfApproval);
        parameters.Add("@LinkValidHours", request.LinkValidHours);
        parameters.Add("@ReminderHours", request.ReminderHours);
        parameters.Add("@NotifyAppApprovers", request.NotifyAppApprovers);
        parameters.Add("@EmailSupplierOnApproval", request.EmailSupplierOnApproval);
        parameters.Add("@CopyToOwners", request.CopyToOwners);
        parameters.Add("@CopyToEmails", request.CopyToEmails);
        parameters.Add("@Approvers", approvers.AsTableValuedParameter(ApproverTypeName));
        parameters.Add("@RowVersion", rowVersion);
        parameters.Add("@UserId", userId);

        await using var connection = _connectionFactory.Create();
        try
        {
            await using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
                "purchase.usp_ApprovalSettings_Save", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            return await ReadSettingsAsync(grid);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public Task<ApprovalMeDto> GetForUserAsync(int userId, CancellationToken cancellationToken = default)
        => SingleAsync<ApprovalMeDto>("purchase.usp_ApprovalSettings_ForUser", new { UserId = userId }, cancellationToken);

    private static async Task<ApprovalSettingsDto> ReadSettingsAsync(SqlMapper.GridReader grid)
    {
        var settings = await grid.ReadSingleOrDefaultAsync<ApprovalRulesDto>() ?? new ApprovalRulesDto();
        var users = (await grid.ReadAsync<ApprovalUserDto>()).AsList();
        return new ApprovalSettingsDto { Settings = settings, Users = users };
    }

    private async Task<IReadOnlyList<T>> QueryAsync<T>(string procedure, object parameters, CancellationToken cancellationToken)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<T>(new CommandDefinition(
                procedure, parameters, commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            return rows.AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    private async Task<T> SingleAsync<T>(string procedure, object parameters, CancellationToken cancellationToken)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            return await connection.QuerySingleAsync<T>(new CommandDefinition(
                procedure, parameters, commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

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
}
