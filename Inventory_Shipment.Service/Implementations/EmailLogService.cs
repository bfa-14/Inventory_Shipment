using System.Globalization;
using System.Net;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Messaging;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;

namespace Inventory_Shipment.Service.Implementations;

public sealed class EmailLogService : IEmailLogService
{
    private readonly IEmailOutboxRepository _outbox;
    private readonly IEmailQueue _queue;
    private readonly IUserRepository _users;
    private readonly TimeProvider _time;

    public EmailLogService(IEmailOutboxRepository outbox, IEmailQueue queue, IUserRepository users, TimeProvider time)
    {
        _outbox = outbox;
        _queue = queue;
        _users = users;
        _time = time;
    }

    public async Task<Result<PagedResult<EmailListDto>>> SearchAsync(EmailQuery query, CancellationToken cancellationToken = default)
    {
        var page = query.Page < 1 ? 1 : query.Page;
        var pageSize = query.PageSize is < 1 or > 200 ? 20 : query.PageSize;
        var (items, totalCount) = await _outbox.SearchAsync(
            new EmailQuery
            {
                Search = query.Search,
                Status = query.Status,
                Category = query.Category,
                RelatedDocumentId = query.RelatedDocumentId,
                DateFrom = query.DateFrom,
                DateTo = query.DateTo,
                Page = page,
                PageSize = pageSize,
            }, cancellationToken);

        return Result<PagedResult<EmailListDto>>.Success(new PagedResult<EmailListDto>
        {
            Items = items,
            Page = page,
            PageSize = pageSize,
            TotalCount = totalCount,
        });
    }

    public async Task<Result<EmailDto>> GetAsync(long id, CancellationToken cancellationToken = default)
    {
        var email = await _outbox.GetAsync(id, cancellationToken);
        return email is null
            ? Result<EmailDto>.Failure(ErrorType.NotFound, "Email not found.", "NOT_FOUND")
            : Result<EmailDto>.Success(ToDto(email));
    }

    public async Task<Result<EmailDto>> RetryAsync(long id, CancellationToken cancellationToken = default)
    {
        try
        {
            await _outbox.RetryAsync(id, cancellationToken);
        }
        catch (BusinessRuleException ex) when (ex.Number == SqlErrors.PurchaseDocumentNotFound)
        {
            return Result<EmailDto>.Failure(ErrorType.NotFound, ex.Message, "NOT_FOUND");
        }

        return await GetAsync(id, cancellationToken);
    }

    public async Task<Result<EmailDto>> QueueTestAsync(int userId, CancellationToken cancellationToken = default)
    {
        var user = await _users.GetByIdAsync(userId, cancellationToken);
        var address = user?.Email?.Trim();
        if (user is null || !EmailAddresses.IsValid(address))
        {
            return Result<EmailDto>.Failure(ErrorType.Validation,
                "Your user has no email address: add one to your user first.", "VALIDATION");
        }

        var at = _time.GetUtcNow().ToString("d MMM yyyy HH:mm 'UTC'", CultureInfo.InvariantCulture);
        var html = "<p style=\"font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1f2937\">"
                   + $"If you can read this, emails leave the application. Queued by {WebUtility.HtmlEncode(user.FullName)} on {at}.</p>";

        var id = await _queue.EnqueueAsync(address, null, "Test email from Inventory & Shipment", html, null,
            EmailCategories.Test, null, userId, cancellationToken);

        return await GetAsync(id, cancellationToken);
    }

    private static EmailDto ToDto(OutboxEmail email) => new()
    {
        Id = email.Id,
        ToAddresses = email.ToAddresses,
        CcAddresses = email.CcAddresses,
        Subject = email.Subject,
        Category = email.Category,
        RelatedDocumentId = email.RelatedDocumentId,
        Status = EmailStatuses.From(email.Status),
        Attempts = email.Attempts,
        NextAttemptAtUtc = email.NextAttemptAtUtc,
        LastError = email.LastError,
        CreatedAtUtc = email.CreatedAtUtc,
        SentAtUtc = email.SentAtUtc,
        AttachmentName = email.AttachmentName,
        AttachmentSize = email.AttachmentContent?.LongLength,
        BodyHtml = email.BodyHtml,
        AttachmentContentType = email.AttachmentContentType,
    };
}
