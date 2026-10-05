using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class AttachmentTypeRepository : IAttachmentTypeRepository
{
    /// <summary>The columns the search procedure will sort by; anything else falls back to the sort order.</summary>
    private static readonly string[] SortColumns = ["SortOrder", "Category", "SubType", "IsActive"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public AttachmentTypeRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>
    /// A row of the search / get procedures: UsedFor comes comma separated (made a list here) and the search adds its
    /// window count, which stays out of the DTO.
    /// </summary>
    private sealed class Row
    {
        public int Id { get; init; }
        public string Category { get; init; } = string.Empty;
        public string SubType { get; init; } = string.Empty;
        public string AppliesTo { get; init; } = "Logistics";
        public int SortOrder { get; init; }
        public bool IsActive { get; init; }
        public string? UsedFor { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public AttachmentTypeDto ToDto() => new()
        {
            Id = Id,
            Category = Category,
            SubType = SubType,
            AppliesTo = AppliesTo,
            SortOrder = SortOrder,
            IsActive = IsActive,
            UsedFor = (UsedFor ?? string.Empty).Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries),
            CreatedAtUtc = CreatedAtUtc,
            UpdatedAtUtc = UpdatedAtUtc,
            RowVersion = RowVersion,
        };
    }

    public async Task<(IReadOnlyList<AttachmentTypeDto> Items, int TotalCount)> SearchAsync(
        AttachmentTypeQuery query, CancellationToken cancellationToken = default)
    {
        var documentKind = string.IsNullOrWhiteSpace(query.DocumentKind) ? null : query.DocumentKind.Trim();
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            Category = string.IsNullOrWhiteSpace(query.Category) ? null : query.Category.Trim(),

            // The types of a kind are what its upload dialog offers: the active ones, unless the page asks otherwise.
            IsActive = query.IsActive ?? (documentKind is null ? null : true),
            DocumentKind = documentKind,
            SortColumn = SortColumns.FirstOrDefault(c => string.Equals(c, query.SortBy, StringComparison.OrdinalIgnoreCase)) ?? "SortOrder",
            SortDirection = string.Equals(query.SortDir, "desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC",
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        var rows = (await connection.QueryAsync<Row>(new CommandDefinition(
            "masterdata.usp_AttachmentType_Search", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();

        return (rows.ConvertAll(r => r.ToDto()), rows.Count > 0 ? rows[0].TotalCount : 0);
    }

    public async Task<AttachmentTypeDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var row = await connection.QuerySingleOrDefaultAsync<Row>(new CommandDefinition(
            "masterdata.usp_AttachmentType_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return row?.ToDto();
    }

    public async Task<IReadOnlyList<AttachmentDocumentKindDto>> GetDocumentKindsAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<AttachmentDocumentKindDto>(new CommandDefinition(
            "masterdata.usp_AttachmentType_DocumentKinds",
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return rows.AsList();
    }

    public async Task<IReadOnlyList<AttachmentTypeLookupDto>> LookupAsync(
        bool activeOnly = true, int? includeId = null, string? appliesTo = null, string? documentKind = null,
        CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<AttachmentTypeLookupDto>(new CommandDefinition(
            "masterdata.usp_AttachmentType_Lookup",
            new { ActiveOnly = activeOnly, IncludeId = includeId, AppliesTo = appliesTo, DocumentKind = documentKind },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return rows.AsList();
    }

    public async Task<int> SaveAsync(
        SaveAttachmentTypeRequest request, int? id, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@Category", request.Category, DbType.String, size: 30);
        parameters.Add("@SubType", request.SubType, DbType.String, size: 60);
        parameters.Add("@AppliesTo", request.AppliesTo, DbType.String, size: 12);
        parameters.Add("@UsedFor", request.UsedFor is null ? null : string.Join(',', request.UsedFor), DbType.String, size: 400);
        parameters.Add("@SortOrder", request.SortOrder, DbType.Int32);
        parameters.Add("@IsActive", request.IsActive, DbType.Boolean);
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await ExecuteAsync("masterdata.usp_AttachmentType_Save", parameters, cancellationToken);
        return parameters.Get<int>("@NewId");
    }

    public Task SetActiveAsync(int id, bool isActive, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("masterdata.usp_AttachmentType_SetActive",
            new { Id = id, IsActive = isActive, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("masterdata.usp_AttachmentType_Delete", new { Id = id, UserId = userId }, cancellationToken);

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
