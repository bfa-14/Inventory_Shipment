namespace Inventory_Shipment.Model.DTOs.Messaging;

/// <summary>
/// What an email is about (messaging.EmailOutbox.Category). The log filters on it and the pages show it,
/// so a new kind of email adds a constant here rather than a free-form string at the call site.
/// </summary>
public static class EmailCategories
{
    public const string Test = "Test";
    public const string PurchaseApproval = "PurchaseApproval";
    public const string PurchaseApprovalReminder = "PurchaseApprovalReminder";
    public const string PurchaseOrderApproved = "PurchaseOrderApproved";
    public const string PurchaseOrderRejected = "PurchaseOrderRejected";
    public const string PurchaseOrderToSupplier = "PurchaseOrderToSupplier";

    public static IReadOnlyList<string> All { get; } =
        [Test, PurchaseApproval, PurchaseApprovalReminder, PurchaseOrderApproved, PurchaseOrderRejected, PurchaseOrderToSupplier];
}

/// <summary>The outbox status: 1 Pending (waiting or being retried), 2 Sent, 3 Failed (gave up after the last attempt).</summary>
public static class EmailStatuses
{
    public const byte PendingCode = 1;
    public const byte SentCode = 2;
    public const byte FailedCode = 3;

    public const string Pending = "Pending";
    public const string Sent = "Sent";
    public const string Failed = "Failed";

    public static string From(byte code) => code switch
    {
        SentCode => Sent,
        FailedCode => Failed,
        _ => Pending,
    };

    public static byte? ToCode(string? status) => status?.Trim().ToLowerInvariant() switch
    {
        "pending" => PendingCode,
        "sent" => SentCode,
        "failed" => FailedCode,
        _ => null,
    };
}

/// <summary>One row of the Email log.</summary>
public class EmailListDto
{
    public long Id { get; init; }

    /// <summary>Addresses separated by ";".</summary>
    public string ToAddresses { get; init; } = string.Empty;

    public string? CcAddresses { get; init; }
    public string Subject { get; init; } = string.Empty;
    public string Category { get; init; } = string.Empty;
    public int? RelatedDocumentId { get; init; }
    public string Status { get; init; } = EmailStatuses.Pending;
    public int Attempts { get; init; }
    public DateTime NextAttemptAtUtc { get; init; }

    /// <summary>The sender's readable explanation of the last failure (never a password).</summary>
    public string? LastError { get; init; }

    public DateTime CreatedAtUtc { get; init; }
    public DateTime? SentAtUtc { get; init; }
    public string? AttachmentName { get; init; }
    public long? AttachmentSize { get; init; }
}

/// <summary>One email with its HTML, for the log's detail view. The attachment itself is not sent to the browser.</summary>
public sealed class EmailDto : EmailListDto
{
    public string BodyHtml { get; init; } = string.Empty;
    public string? AttachmentContentType { get; init; }
}

public sealed class EmailQuery
{
    /// <summary>A recipient or a word of the subject.</summary>
    public string? Search { get; init; }

    /// <summary>Pending | Sent | Failed.</summary>
    public string? Status { get; init; }

    public string? Category { get; init; }
    public int? RelatedDocumentId { get; init; }
    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 20;
}

/// <summary>A file sent with an email (the order's Excel file, for instance).</summary>
public sealed record EmailAttachment(string FileName, string ContentType, byte[] Content);

/// <summary>An email as the outbox holds it, attachment included: what the sender sends.</summary>
public sealed class OutboxEmail
{
    public long Id { get; init; }
    public string ToAddresses { get; init; } = string.Empty;
    public string? CcAddresses { get; init; }
    public string Subject { get; init; } = string.Empty;
    public string BodyHtml { get; init; } = string.Empty;
    public string? AttachmentName { get; init; }
    public string? AttachmentContentType { get; init; }
    public byte[]? AttachmentContent { get; init; }
    public string Category { get; init; } = string.Empty;
    public int? RelatedDocumentId { get; init; }
    public byte Status { get; init; }
    public int Attempts { get; init; }
    public DateTime NextAttemptAtUtc { get; init; }
    public string? LastError { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public DateTime? SentAtUtc { get; init; }
}
