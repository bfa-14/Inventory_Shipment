using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Reports;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class AttachmentReportRepository : IAttachmentReportRepository
{
    private readonly ISqlConnectionFactory _connectionFactory;

    public AttachmentReportRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<(IReadOnlyList<AttachmentReportRowDto> Rows, int TotalCount, long TotalBytes)> ListAsync(
        AttachmentReportQuery query, IReadOnlyCollection<string> kinds, CancellationToken cancellationToken = default)
    {
        var parameters = FilterParameters(query, kinds);
        parameters.Add("Page", query.Page, DbType.Int32);
        parameters.Add("PageSize", query.PageSize, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        using var grid = await connection.QueryMultipleAsync(new CommandDefinition(
            "reporting.usp_AttachmentReport_List", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var rows = (await grid.ReadAsync<AttachmentReportRowDto>()).ToList();
        var totals = await grid.ReadSingleAsync<(int TotalCount, long TotalBytes)>();
        return (rows, totals.TotalCount, totals.TotalBytes);
    }

    public async Task<IReadOnlyList<AttachmentReportRowDto>> FilesAsync(
        AttachmentReportFilters filters, IReadOnlyCollection<string>? keys, IReadOnlyCollection<string> kinds,
        CancellationToken cancellationToken = default)
    {
        var parameters = FilterParameters(filters, kinds);
        parameters.Add("Keys", keys is null ? null : string.Join(',', keys), DbType.String, size: -1);

        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<AttachmentReportRowDto>(new CommandDefinition(
            "reporting.usp_AttachmentReport_Files", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        return rows.ToList();
    }

    public async Task ReadContentsAsync(
        IReadOnlyCollection<string> keys, Func<string, Stream, Task> write, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        await connection.OpenAsync(cancellationToken);
        await using var command = new SqlCommand("reporting.usp_AttachmentReport_Content", connection)
        {
            CommandType = CommandType.StoredProcedure,
        };
        if (_connectionFactory.BatchCommandTimeout is { } timeout) command.CommandTimeout = timeout;
        command.Parameters.Add(new SqlParameter("@Keys", SqlDbType.NVarChar, -1) { Value = string.Join(',', keys) });

        // SEQUENTIAL ACCESS: each file's bytes are read as a stream, in order, never buffered whole.
        await using var reader = await command.ExecuteReaderAsync(CommandBehavior.SequentialAccess, cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            var key = $"{reader.GetString(0)}:{reader.GetInt32(1)}";
            if (await reader.IsDBNullAsync(2, cancellationToken)) continue;
            await using var content = reader.GetStream(2);
            await write(key, content);
        }
    }

    public async Task LogDownloadAsync(
        int userId, string mode, int fileCount, long totalBytes, string? criteria, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        await connection.ExecuteAsync(new CommandDefinition(
            "reporting.usp_AttachmentReport_LogDownload",
            new { UserId = userId, Mode = mode, FileCount = fileCount, TotalBytes = totalBytes, Criteria = criteria },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    public async Task<IReadOnlyList<AttachmentReportTypeDto>> TypesAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<AttachmentReportTypeDto>(new CommandDefinition(
            "SELECT Id, Category, SubType, IsActive FROM masterdata.AttachmentTypes ORDER BY Category, SortOrder, SubType;",
            cancellationToken: cancellationToken));
        return rows.ToList();
    }

    /// <summary>The filters every procedure of the report takes. Dates go as DATE, lists as comma-separated text.</summary>
    private static DynamicParameters FilterParameters(AttachmentReportFilters filters, IReadOnlyCollection<string> kinds)
    {
        var parameters = new DynamicParameters();
        parameters.Add("Kinds", string.Join(',', kinds), DbType.String, size: 400);
        parameters.Add("TypeIds", filters.TypeIds is { Length: > 0 } ids ? string.Join(',', ids) : null, DbType.String, size: -1);
        parameters.Add("DocFrom", filters.DocumentDateFrom?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("DocTo", filters.DocumentDateTo?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("UploadFrom", filters.UploadedFrom?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("UploadTo", filters.UploadedTo?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        return parameters;
    }
}
