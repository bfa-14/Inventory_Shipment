using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class ContainerChargeRepository : IContainerChargeRepository
{
    /// <summary>Matched by TYPE NAME on the server; a wrong one fails with a message that never mentions the type.</summary>
    private const string IdListTypeName = "logistics.tvp_IdList";
    private const string ManualTypeName = "logistics.tvp_ChargeManual";

    /// <summary>The columns the search procedure will sort by; anything else falls back to the charge date.</summary>
    private static readonly string[] SortColumns = ["ChargeDate", "ContainerRef", "ChargeName", "AmountBase", "Status", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public ContainerChargeRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>The list row plus the two window figures the procedure adds; serialized as the base type.</summary>
    private sealed record ListRow : ContainerChargeListDto
    {
        public decimal TotalAmountBase { get; init; }
        public int TotalCount { get; init; }
    }

    public async Task<(IReadOnlyList<ContainerChargeListDto> Items, int TotalCount, decimal TotalAmountBase)> SearchAsync(
        ContainerChargeQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.ContainerId,
            query.MovementId,
            query.ChargeTypeId,
            query.ProviderPartyId,
            Status = ContainerChargeStatus.ToCode(query.Status),
            DateFrom = query.DateFrom?.ToDateTime(TimeOnly.MinValue),
            DateTo = query.DateTo?.ToDateTime(TimeOnly.MinValue),
            SortColumn = SortColumns.FirstOrDefault(c => string.Equals(c, query.SortBy, StringComparison.OrdinalIgnoreCase)) ?? "ChargeDate",
            SortDirection = string.Equals(query.SortDir, "asc", StringComparison.OrdinalIgnoreCase) ? "ASC" : "DESC",
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        var rows = (await connection.QueryAsync<ListRow>(new CommandDefinition(
            "logistics.usp_ContainerCharge_Search", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();

        // Both figures are windows over the whole filter: any row carries them. A page past the end
        // has no row, and then no total either — the page asks for page 1 when the filter changes.
        return rows.Count > 0 ? (rows, rows[0].TotalCount, rows[0].TotalAmountBase) : (rows, 0, 0m);
    }

    public async Task<ContainerChargeDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "logistics.usp_ContainerCharge_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var header = await multi.ReadSingleOrDefaultAsync<ContainerChargeDto>();
        if (header is null)
        {
            return null;
        }

        var allocations = (await multi.ReadAsync<ContainerChargeShareDto>()).AsList();
        var attachments = (await multi.ReadAsync<ContainerChargeAttachmentDto>()).AsList();
        var group = (await multi.ReadAsync<ContainerChargeGroupMemberDto>()).AsList();

        return header with { Allocations = allocations, Attachments = attachments, Group = group };
    }

    public async Task<IReadOnlyList<ContainerChargeGroupMemberDto>> CreateAsync(
        CreateContainerChargeRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@ContainerIds", MovementRepository.ToIdTable(request.ContainerIds).AsTableValuedParameter(IdListTypeName));
        parameters.Add("@MovementId", request.MovementId, DbType.Int32);
        parameters.Add("@ChargeTypeId", request.ChargeTypeId, DbType.Int32);
        parameters.Add("@Description", request.Description, DbType.String, size: 200);
        parameters.Add("@ProviderPartyId", request.ProviderPartyId, DbType.Int32);
        parameters.Add("@Reference", request.Reference, DbType.String, size: 100);
        parameters.Add("@ChargeDate", request.ChargeDate.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@CurrencyId", request.CurrencyId, DbType.Int32);
        parameters.Add("@RateType", request.RateType, DbType.Byte);
        parameters.Add("@ExchangeRate", request.ExchangeRate, DbType.Decimal, precision: 18, scale: 6);
        parameters.Add("@TotalAmount", request.TotalAmount, DbType.Decimal, precision: 18, scale: 2);
        parameters.Add("@SplitRule", ChargeSplitRules.Normalize(request.SplitRule) ?? request.SplitRule, DbType.String, size: 10);
        parameters.Add("@AllocationMethod", ContainerChargeMethods.Normalize(request.AllocationMethod), DbType.String, size: 10);
        parameters.Add("@Notes", request.Notes, DbType.String, size: 300);
        parameters.Add("@UserId", userId, DbType.Int32);

        try
        {
            IReadOnlyList<ContainerChargeGroupMemberDto> created = [];
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                created = (await connection.QueryAsync<ContainerChargeGroupMemberDto>(new CommandDefinition(
                    "logistics.usp_ContainerCharge_Create", parameters,
                    commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();
            }, cancellationToken);

            return created;
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public Task UpdateAsync(int id, UpdateContainerChargeRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@MovementId", request.MovementId, DbType.Int32);
        parameters.Add("@ChargeTypeId", request.ChargeTypeId, DbType.Int32);
        parameters.Add("@Description", request.Description, DbType.String, size: 200);
        parameters.Add("@ProviderPartyId", request.ProviderPartyId, DbType.Int32);
        parameters.Add("@Reference", request.Reference, DbType.String, size: 100);
        parameters.Add("@ChargeDate", request.ChargeDate.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@CurrencyId", request.CurrencyId, DbType.Int32);
        parameters.Add("@RateType", request.RateType, DbType.Byte);
        parameters.Add("@ExchangeRate", request.ExchangeRate, DbType.Decimal, precision: 18, scale: 6);
        parameters.Add("@Amount", request.Amount, DbType.Decimal, precision: 18, scale: 2);
        parameters.Add("@AllocationMethod", ContainerChargeMethods.Normalize(request.AllocationMethod), DbType.String, size: 10);
        parameters.Add("@Notes", request.Notes, DbType.String, size: 300);
        parameters.Add("@Manual", ToManualTable(request.Manual).AsTableValuedParameter(ManualTypeName));
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);

        return ExecuteAsync("logistics.usp_ContainerCharge_Update", parameters, cancellationToken);
    }

    public Task PostAsync(int? id, IReadOnlyList<int> ids, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@Ids", MovementRepository.ToIdTable(ids).AsTableValuedParameter(IdListTypeName));
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);

        return ExecuteAsync("logistics.usp_ContainerCharge_Post", parameters, cancellationToken);
    }

    public Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_ContainerCharge_Cancel",
            new { Id = id, Reason = reason, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_ContainerCharge_Delete", new { Id = id, UserId = userId }, cancellationToken);

    /// <summary>
    /// One procedure call, run again if SQL Server made it the deadlock victim: posting or cancelling
    /// a charge after the offload writes cost adjustments and moves the average cost of every item on
    /// board, like an offload does.
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

    /// <summary>logistics.tvp_ChargeManual (ContainerLineId, AmountBase).</summary>
    private static DataTable ToManualTable(IReadOnlyList<ChargeManualShareRequest> shares)
    {
        var table = new DataTable();
        table.Columns.Add("ContainerLineId", typeof(int));
        table.Columns.Add("AmountBase", typeof(decimal));
        foreach (var share in shares)
        {
            table.Rows.Add(share.ContainerLineId, share.AmountBase);
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
