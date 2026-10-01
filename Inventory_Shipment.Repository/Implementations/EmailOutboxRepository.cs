using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Messaging;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class EmailOutboxRepository : IEmailOutboxRepository
{
    private readonly ISqlConnectionFactory _connectionFactory;

    public EmailOutboxRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>A row of usp_Email_Search: the status as the procedure's number, and the window count.</summary>
    private sealed class SearchRow
    {
        public long Id { get; init; }
        public string ToAddresses { get; init; } = string.Empty;
        public string? CcAddresses { get; init; }
        public string Subject { get; init; } = string.Empty;
        public string Category { get; init; } = string.Empty;
        public int? RelatedDocumentId { get; init; }
        public byte Status { get; init; }
        public int Attempts { get; init; }
        public DateTime NextAttemptAtUtc { get; init; }
        public string? LastError { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public DateTime? SentAtUtc { get; init; }
        public string? AttachmentName { get; init; }
        public long? AttachmentSize { get; init; }
        public int TotalCount { get; init; }
    }

    public async Task<long> EnqueueAsync(
        string toAddresses, string? ccAddresses, string subject, string bodyHtml, EmailAttachment? attachment,
        string category, int? relatedDocumentId, int? userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@ToAddresses", toAddresses);
        parameters.Add("@CcAddresses", ccAddresses);
        parameters.Add("@Subject", subject);
        parameters.Add("@BodyHtml", bodyHtml);
        parameters.Add("@AttachmentName", attachment?.FileName);
        parameters.Add("@AttachmentContentType", attachment?.ContentType);
        parameters.Add("@AttachmentContent", attachment?.Content, DbType.Binary, size: -1);
        parameters.Add("@Category", category);
        parameters.Add("@RelatedDocumentId", relatedDocumentId);
        parameters.Add("@UserId", userId);
        parameters.Add("@NewId", dbType: DbType.Int64, direction: ParameterDirection.Output);

        await ExecuteAsync("messaging.usp_Email_Enqueue", parameters, cancellationToken);
        return parameters.Get<long>("@NewId");
    }

    public async Task<IReadOnlyList<long>> ClaimAsync(int batchSize, int leaseMinutes, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var ids = await connection.QueryAsync<long>(new CommandDefinition(
            "messaging.usp_Email_Claim", new { BatchSize = batchSize, LeaseMinutes = leaseMinutes },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return ids.AsList();
    }

    public async Task<OutboxEmail?> GetAsync(long id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<OutboxEmail>(new CommandDefinition(
            "messaging.usp_Email_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    public Task MarkSentAsync(long id, CancellationToken cancellationToken = default)
        => ExecuteAsync("messaging.usp_Email_MarkSent", new { Id = id }, cancellationToken);

    public Task MarkFailedAsync(long id, string error, int maxAttempts, CancellationToken cancellationToken = default)
        => ExecuteAsync("messaging.usp_Email_MarkFailed", new { Id = id, Error = error, MaxAttempts = maxAttempts }, cancellationToken);

    public Task RetryAsync(long id, CancellationToken cancellationToken = default)
        => ExecuteAsync("messaging.usp_Email_Retry", new { Id = id }, cancellationToken);

    public async Task<(IReadOnlyList<EmailListDto> Items, int TotalCount)> SearchAsync(
        EmailQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            Status = EmailStatuses.ToCode(query.Status),
            Category = string.IsNullOrWhiteSpace(query.Category) ? null : query.Category.Trim(),
            query.RelatedDocumentId,
            DateFrom = query.DateFrom?.ToDateTime(TimeOnly.MinValue),
            DateTo = query.DateTo?.ToDateTime(TimeOnly.MinValue),
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        var rows = (await connection.QueryAsync<SearchRow>(new CommandDefinition(
            "messaging.usp_Email_Search", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();

        IReadOnlyList<EmailListDto> items = rows.Select(r => new EmailListDto
        {
            Id = r.Id,
            ToAddresses = r.ToAddresses,
            CcAddresses = r.CcAddresses,
            Subject = r.Subject,
            Category = r.Category,
            RelatedDocumentId = r.RelatedDocumentId,
            Status = EmailStatuses.From(r.Status),
            Attempts = r.Attempts,
            NextAttemptAtUtc = r.NextAttemptAtUtc,
            LastError = r.LastError,
            CreatedAtUtc = r.CreatedAtUtc,
            SentAtUtc = r.SentAtUtc,
            AttachmentName = r.AttachmentName,
            AttachmentSize = r.AttachmentSize,
        }).ToList();

        return (items, rows.Count > 0 ? rows[0].TotalCount : 0);
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
