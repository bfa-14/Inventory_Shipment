using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Model.Enums;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class PartyRepository : IPartyRepository
{
    /// <summary>Columns the search procedure accepts; anything else falls back to PartyCode.</summary>
    private static readonly string[] SortColumns =
        ["PartyCode", "PartyName", "BranchName", "Email", "Phone", "IsActive", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public PartyRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>Flat shape the search procedure returns: every column plus the windowed total.</summary>
    private sealed class PartyRow
    {
        public int Id { get; init; }
        public string PartyCode { get; init; } = string.Empty;
        public string PartyName { get; init; } = string.Empty;
        public bool IsSupplier { get; init; }
        public bool IsClient { get; init; }
        public bool IsSalesman { get; init; }
        public bool IsEmployee { get; init; }
        public int? BranchId { get; init; }
        public string? BranchCode { get; init; }
        public string? BranchName { get; init; }
        public string? ContactPerson { get; init; }
        public string? Phone { get; init; }
        public string? Mobile { get; init; }
        public string? Email { get; init; }
        public string? Address { get; init; }
        public string? Country { get; init; }
        public string? TaxRegistrationNo { get; init; }
        public string? Notes { get; init; }
        public int? UserId { get; init; }
        public string? UserName { get; init; }
        public string? UserFullName { get; init; }
        public int? DefaultPriceListId { get; init; }
        public string? DefaultPriceListName { get; init; }
        public int? DefaultCurrencyId { get; init; }
        public string? DefaultCurrencyCode { get; init; }
        public bool IsActive { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public int? CreatedBy { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public int? UpdatedBy { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public Party ToParty() => new()
        {
            Id = Id,
            PartyCode = PartyCode,
            PartyName = PartyName,
            IsSupplier = IsSupplier,
            IsClient = IsClient,
            IsSalesman = IsSalesman,
            IsEmployee = IsEmployee,
            BranchId = BranchId,
            BranchCode = BranchCode,
            BranchName = BranchName,
            ContactPerson = ContactPerson,
            Phone = Phone,
            Mobile = Mobile,
            Email = Email,
            Address = Address,
            Country = Country,
            TaxRegistrationNo = TaxRegistrationNo,
            Notes = Notes,
            UserId = UserId,
            UserName = UserName,
            UserFullName = UserFullName,
            DefaultPriceListId = DefaultPriceListId,
            DefaultPriceListName = DefaultPriceListName,
            DefaultCurrencyId = DefaultCurrencyId,
            DefaultCurrencyCode = DefaultCurrencyCode,
            IsActive = IsActive,
            CreatedAtUtc = CreatedAtUtc,
            CreatedBy = CreatedBy,
            UpdatedAtUtc = UpdatedAtUtc,
            UpdatedBy = UpdatedBy,
            RowVersion = RowVersion
        };
    }

    public async Task<(IReadOnlyList<Party> Items, int TotalCount)> SearchAsync(
        PartyQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            PartyType = query.PartyType?.ToString(),
            query.BranchId,
            query.IsActive,
            SortColumn = ResolveSortColumn(query.SortBy),
            SortDirection = ResolveSortDirection(query.SortDir),
            PageNumber = query.Page,
            query.PageSize
        };

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<PartyRow>(new CommandDefinition(
                "masterdata.usp_Party_Search", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var list = rows.AsList();
            // The procedure repeats the same COUNT(*) OVER () on every row; no rows means nothing matched.
            var total = list.Count > 0 ? list[0].TotalCount : 0;
            return (list.Select(r => r.ToParty()).ToList(), total);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<Party?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            return await connection.QuerySingleOrDefaultAsync<Party>(new CommandDefinition(
                "masterdata.usp_Party_Get", new { Id = id },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<IReadOnlyList<PartyLookup>> LookupAsync(
        PartyType? partyType, string? search, bool activeOnly, int? includeId, int top,
        CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            PartyType = partyType?.ToString(),
            Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim(),
            ActiveOnly = activeOnly,
            IncludeId = includeId,
            Top = top
        };

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<PartyLookup>(new CommandDefinition(
                "masterdata.usp_Party_Lookup", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            return rows.AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<string> NextCodeAsync(PartyType partyType, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            return await connection.ExecuteScalarAsync<string>(new CommandDefinition(
                "masterdata.usp_Party_NextCode", new { PartyType = partyType.ToString() },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken)) ?? string.Empty;
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<int> CreateAsync(Party party, int? actorUserId, CancellationToken cancellationToken = default)
    {
        var parameters = BuildSaveParameters(party);
        parameters.Add("@ActorUserId", actorUserId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_Party_Create", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var id = parameters.Get<int>("@NewId");
            party.Id = id;
            return id;
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task UpdateAsync(
        Party party, byte[]? rowVersion, int? actorUserId, CancellationToken cancellationToken = default)
    {
        var parameters = BuildSaveParameters(party);
        parameters.Add("@Id", party.Id, DbType.Int32);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@ActorUserId", actorUserId, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_Party_Update", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task SetActiveAsync(
        int id, bool isActive, int? actorUserId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_Party_SetActive",
                new { Id = id, IsActive = isActive, ActorUserId = actorUserId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task DeleteAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "masterdata.usp_Party_Delete", new { Id = id },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    // ----- helpers -----

    /// <summary>
    /// The columns Create and Update share. The party's own <c>UserId</c> is the linked application
    /// user; who is saving travels separately as <c>@ActorUserId</c>.
    /// </summary>
    private static DynamicParameters BuildSaveParameters(Party party)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@PartyCode", party.PartyCode, DbType.String, size: 20);
        parameters.Add("@PartyName", party.PartyName, DbType.String, size: 200);
        parameters.Add("@IsSupplier", party.IsSupplier, DbType.Boolean);
        parameters.Add("@IsClient", party.IsClient, DbType.Boolean);
        parameters.Add("@IsSalesman", party.IsSalesman, DbType.Boolean);
        parameters.Add("@IsEmployee", party.IsEmployee, DbType.Boolean);
        parameters.Add("@BranchId", party.BranchId, DbType.Int32);
        parameters.Add("@ContactPerson", party.ContactPerson, DbType.String, size: 150);
        parameters.Add("@Phone", party.Phone, DbType.String, size: 50);
        parameters.Add("@Mobile", party.Mobile, DbType.String, size: 50);
        parameters.Add("@Email", party.Email, DbType.String, size: 150);
        parameters.Add("@Address", party.Address, DbType.String, size: 500);
        parameters.Add("@Country", party.Country, DbType.String, size: 2);
        parameters.Add("@TaxRegistrationNo", party.TaxRegistrationNo, DbType.String, size: 50);
        parameters.Add("@Notes", party.Notes, DbType.String, size: 1000);
        parameters.Add("@UserId", party.UserId, DbType.Int32);
        parameters.Add("@DefaultPriceListId", party.DefaultPriceListId, DbType.Int32);
        parameters.Add("@DefaultCurrencyId", party.DefaultCurrencyId, DbType.Int32);
        parameters.Add("@IsActive", party.IsActive, DbType.Boolean);
        return parameters;
    }

    private static string ResolveSortColumn(string? sortBy)
        => SortColumns.FirstOrDefault(c => string.Equals(c, sortBy, StringComparison.OrdinalIgnoreCase))
           ?? "PartyCode";

    private static string ResolveSortDirection(string? sortDir)
        => string.Equals(sortDir, "desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC";
}
