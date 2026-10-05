using System.Data;
using System.Data.Common;
using Dapper;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class PurchaseInvoiceContainerRepository : IPurchaseInvoiceContainerRepository
{
    private const string LinkTypeName = "logistics.tvp_ContainerLineQty";

    private readonly ISqlConnectionFactory _connectionFactory;

    public PurchaseInvoiceContainerRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<InvoiceContainerSummaryDto> GetSummaryAsync(int invoiceId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "purchase.usp_PurchaseInvoice_ContainerSummary", new { InvoiceId = invoiceId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return await ReadSummaryAsync(multi);
    }

    public async Task<IReadOnlyList<InvoiceLinkCandidateDto>> GetCandidatesAsync(int invoiceId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<InvoiceLinkCandidateDto>(new CommandDefinition(
            "purchase.usp_PurchaseInvoice_LinkCandidates", new { InvoiceId = invoiceId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return rows.AsList();
    }

    public async Task<InvoiceContainerStateDto?> GetStateAsync(int invoiceId, int? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<InvoiceContainerStateDto>(new CommandDefinition(
            "purchase.usp_PurchaseInvoice_ContainerState", new { Id = invoiceId, UserId = userId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    public async Task CheckAsync(int invoiceId, string action, int? quantityBase, CancellationToken cancellationToken = default)
    {
        try
        {
            await using var connection = _connectionFactory.Create();
            await connection.ExecuteAsync(new CommandDefinition(
                "purchase.usp_PurchaseInvoice_CheckContainers",
                new { InvoiceId = invoiceId, Action = action, QuantityBase = quantityBase },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public Task<InvoiceContainerSummaryDto> LinkAsync(
        int invoiceId, IReadOnlyList<ContainerLineQuantityRequest> links, byte[]? rowVersion, int userId,
        CancellationToken cancellationToken = default)
        => InTransactionAsync(async (connection, transaction) =>
        {
            using var multi = await connection.QueryMultipleAsync(LinkCommand(invoiceId, links, rowVersion, userId, transaction, cancellationToken));
            return await ReadSummaryAsync(multi);
        }, cancellationToken);

    public Task<InvoiceContainerSummaryDto> UnlinkAsync(
        int invoiceId, int containerId, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => InTransactionAsync(async (connection, transaction) =>
        {
            using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
                "purchase.usp_PurchaseInvoice_UnlinkContainer",
                new { InvoiceId = invoiceId, ContainerId = containerId, RowVersion = rowVersion, UserId = userId },
                transaction, commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            return await ReadSummaryAsync(multi);
        }, cancellationToken);

    public Task<InvoiceContainersCreatedDto> AddContainerAsync(
        int invoiceId, SaveContainerRequest container, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => InTransactionAsync(async (connection, transaction) =>
        {
            var parameters = ContainerRepository.SaveParameters(container, null, userId);
            parameters.Add("@ForInvoiceId", invoiceId, DbType.Int32);
            await connection.ExecuteAsync(new CommandDefinition(
                "logistics.usp_Container_Save", parameters, transaction,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            var containerId = parameters.Get<int>("@NewId");

            var created = await connection.QuerySingleAsync<CreatedContainerDto>(new CommandDefinition(
                """
                SELECT Seq = 1, ContainerId = c.Id, c.ContainerRef, c.Status, c.TotalLines, c.TotalAllocatedBase,
                       fl.FillPct, fl.CapacityKnown, fl.IsOverCapacity, c.RowVersion
                FROM logistics.Containers c CROSS APPLY logistics.fn_ContainerFill(c.Id) fl WHERE c.Id = @ContainerId
                """,
                new { ContainerId = containerId }, transaction, cancellationToken: cancellationToken));

            var summary = await LinkWholeContainersAsync(connection, transaction, invoiceId, [containerId], rowVersion, userId, cancellationToken);
            return new InvoiceContainersCreatedDto { Created = [created], Summary = summary };
        }, cancellationToken);

    public Task<InvoiceContainersCreatedDto> CreateFromPlanAsync(
        int invoiceId, CreateContainersFromPlanRequest plan, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => InTransactionAsync(async (connection, transaction) =>
        {
            var parameters = ContainerRepository.CreateBatchParameters(plan, userId);
            parameters.Add("@ForInvoiceId", invoiceId, DbType.Int32);
            var created = (await connection.QueryAsync<CreatedContainerDto>(new CommandDefinition(
                "logistics.usp_Container_CreateBatch", parameters, transaction,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();

            var summary = await LinkWholeContainersAsync(
                connection, transaction, invoiceId, created.Select(c => c.ContainerId).ToList(), rowVersion, userId, cancellationToken);
            return new InvoiceContainersCreatedDto { Created = created, Summary = summary };
        }, cancellationToken);

    /* ── the shared steps ─────────────────────────────────────────────────────────────────────── */

    /// <summary>Every line of the given new containers, linked to the invoice with all its pieces.</summary>
    private static async Task<InvoiceContainerSummaryDto> LinkWholeContainersAsync(
        DbConnection connection, DbTransaction transaction, int invoiceId, IReadOnlyList<int> containerIds, byte[]? rowVersion,
        int userId, CancellationToken cancellationToken)
    {
        var links = (await connection.QueryAsync<ContainerLineQuantityRequest>(new CommandDefinition(
            "SELECT ContainerLineId = Id, QuantityBase FROM logistics.ContainerLines WHERE ContainerId IN @ContainerIds",
            new { ContainerIds = containerIds }, transaction, cancellationToken: cancellationToken))).AsList();

        using var multi = await connection.QueryMultipleAsync(LinkCommand(invoiceId, links, rowVersion, userId, transaction, cancellationToken));
        return await ReadSummaryAsync(multi);
    }

    private static CommandDefinition LinkCommand(
        int invoiceId, IReadOnlyList<ContainerLineQuantityRequest> links, byte[]? rowVersion, int userId,
        DbTransaction transaction, CancellationToken cancellationToken)
    {
        var table = new DataTable();
        table.Columns.Add("ContainerLineId", typeof(int));
        table.Columns.Add("QuantityBase", typeof(int));
        foreach (var link in links)
        {
            table.Rows.Add(link.ContainerLineId, link.QuantityBase);
        }

        var parameters = new DynamicParameters();
        parameters.Add("@InvoiceId", invoiceId, DbType.Int32);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@Links", table.AsTableValuedParameter(LinkTypeName));
        parameters.Add("@UserId", userId, DbType.Int32);

        return new CommandDefinition("purchase.usp_PurchaseInvoice_LinkContainers", parameters, transaction,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken);
    }

    private static async Task<InvoiceContainerSummaryDto> ReadSummaryAsync(SqlMapper.GridReader multi)
    {
        var items = (await multi.ReadAsync<InvoiceContainerItemDto>()).AsList();
        var containers = (await multi.ReadAsync<InvoiceLinkedContainerDto>()).AsList();
        return new InvoiceContainerSummaryDto { Items = items, Containers = containers };
    }

    /// <summary>
    /// ONE CONNECTION, ONE TRANSACTION for everything the work does: containers created on the order and their link to
    /// the invoice stand or fall together. The procedures' own transactions nest inside it, and a procedure that fails
    /// rolls the whole of it back before it throws; the transaction is then only disposed. Run again if SQL Server made
    /// it the deadlock victim: it touches the order, its containers and the invoice.
    /// </summary>
    private async Task<T> InTransactionAsync<T>(Func<DbConnection, DbTransaction, Task<T>> work, CancellationToken cancellationToken)
    {
        try
        {
            T result = default!;
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.OpenAsync(cancellationToken);
                await using var transaction = await connection.BeginTransactionAsync(cancellationToken);
                result = await work(connection, transaction);
                await transaction.CommitAsync(cancellationToken);
            }, cancellationToken);

            return result;
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }
}
