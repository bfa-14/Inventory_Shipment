using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Messaging;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class EmailSettingsRepository : IEmailSettingsRepository
{
    private readonly ISqlConnectionFactory _connectionFactory;

    public EmailSettingsRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<EmailSettingsRow?> GetAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<EmailSettingsRow>(new CommandDefinition(
            "messaging.usp_EmailSettings_Get", commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    public async Task<EmailSettingsSendingRow?> GetForSendingAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<EmailSettingsSendingRow>(new CommandDefinition(
            "messaging.usp_EmailSettings_GetForSending", commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    public async Task<EmailSettingsRow?> SaveAsync(EmailSettingsSave save, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            save.SendingEnabled,
            save.SmtpHost,
            save.SmtpPort,
            save.SmtpSecurity,
            save.SmtpUserName,
            save.PasswordAction,
            save.SmtpPasswordProtected,
            save.FromAddress,
            save.FromName,
            save.ReplyToAddress,
            save.PublicBaseUrl,
            save.RowVersion,
            save.UserId,
        };

        await using var connection = _connectionFactory.Create();
        try
        {
            return await connection.QuerySingleOrDefaultAsync<EmailSettingsRow>(new CommandDefinition(
                "messaging.usp_EmailSettings_Save", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<byte[]> SetTestResultAsync(bool ok, string? error, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            return await connection.QuerySingleAsync<byte[]>(new CommandDefinition(
                "messaging.usp_EmailSettings_SetTestResult", new { Ok = ok, Error = error },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }
}
