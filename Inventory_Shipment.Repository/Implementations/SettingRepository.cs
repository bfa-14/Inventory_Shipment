using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Configuration;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class SettingRepository : ISettingRepository
{
    private readonly ISqlConnectionFactory _connectionFactory;

    public SettingRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<IReadOnlyList<SettingDto>> ListAsync(bool onlyPublic, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<SettingDto>(new CommandDefinition(
            "configuration.usp_Setting_List", new { OnlyPublic = onlyPublic },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return rows.AsList();
    }

    public async Task<string?> GetValueAsync(string settingKey, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT configuration.fn_SettingValue(@SettingKey)", new { SettingKey = settingKey },
            cancellationToken: cancellationToken));
    }

    public Task SaveAsync(string settingKey, string? value, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("configuration.usp_Setting_Save", new { SettingKey = settingKey, Value = value, UserId = userId }, cancellationToken);

    public Task ResetAsync(string settingKey, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("configuration.usp_Setting_Reset", new { SettingKey = settingKey, UserId = userId }, cancellationToken);

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
