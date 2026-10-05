using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Documents;

/// <summary>
/// The rules every attachment endpoint shares (script 48): what a file may be, how big, how long its note. The
/// containers' list since script 27 - what a forwarder, a customs agent, a supplier or a customer sends.
/// </summary>
public static class AttachmentRules
{
    public const long MaxFileBytes = 20 * 1024 * 1024;

    /// <summary>
    /// The request around the file, with room to spare: a file a little over the limit must reach
    /// <see cref="CheckFile"/> ("larger than 20 MB") rather than be cut off by the form reader.
    /// </summary>
    public const long MaxRequestBytes = 2 * MaxFileBytes;

    public const int NoteMaxLength = 500;

    public static readonly IReadOnlySet<string> AllowedExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        ".pdf", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".tif", ".tiff",
        ".xlsx", ".xls", ".docx", ".doc", ".pptx", ".ppt", ".csv", ".txt",
    };

    public const string TypeRequired = "Choose the attachment type.";

    /// <summary>The refusal of a file, or null when it may be attached.</summary>
    public static string? CheckFile(string? fileName, long length)
    {
        if (string.IsNullOrEmpty(fileName) || length == 0)
        {
            return "No file was uploaded.";
        }

        if (length > MaxFileBytes)
        {
            return $"The file is larger than {MaxFileBytes / (1024 * 1024)} MB.";
        }

        return AllowedExtensions.Contains(Path.GetExtension(fileName))
            ? null
            : "Only PDF, image and office files (Word, Excel, PowerPoint, CSV, text) can be attached.";
    }

    /// <summary>The refusal of the type / date / note of a file, or null.</summary>
    public static string? CheckFields(DocumentFileFields fields)
    {
        if (fields.AttachmentTypeId is null)
        {
            return TypeRequired;
        }

        return fields.Note is { Length: > NoteMaxLength } ? $"The note is longer than {NoteMaxLength} characters." : null;
    }

    /// <summary>The type "Other": files uploaded before types existed get it, and the pages ask for a real one.</summary>
    public static bool IsOther(int? attachmentTypeId, string? category, string? subType)
        => attachmentTypeId is null
           || (string.Equals(subType, "Other", StringComparison.OrdinalIgnoreCase)
               && (string.Equals(category, "Other", StringComparison.OrdinalIgnoreCase)
                   || string.Equals(category, "General", StringComparison.OrdinalIgnoreCase)));
}

/// <summary>
/// The type, date and note of a file: the form fields of an upload, the body of PUT .../files/{fileId}. The type is
/// required and must be active and used for the document's kind (api/masterdata/attachment-types?documentKind=).
/// </summary>
public sealed class DocumentFileFields
{
    public int? AttachmentTypeId { get; init; }

    /// <summary>The date written on the document (the invoice date of a proforma, the B/L date...).</summary>
    public DateOnly? DocumentDate { get; init; }

    [StringLength(AttachmentRules.NoteMaxLength)]
    public string? Note { get; init; }
}

/// <summary>
/// One file attached to a purchase, sales or stock document or a customer receipt, with its type, date and note.
/// The bytes are fetched separately, by id.
/// </summary>
public sealed class DocumentFileDto
{
    public int Id { get; init; }

    /// <summary>The document (or the receipt) the file is attached to.</summary>
    public int DocumentId { get; init; }

    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public int SizeBytes { get; init; }
    public int? AttachmentTypeId { get; init; }

    /// <summary>"Purchase" of "Purchase › Proforma Invoice".</summary>
    public string? Category { get; init; }

    public string? SubType { get; init; }

    /// <summary>Typed "Other": the page shows "Choose a type" next to the edit button.</summary>
    public bool IsOther => AttachmentRules.IsOther(AttachmentTypeId, Category, SubType);

    public DateTime? DocumentDate { get; init; }
    public string? Note { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public int? CreatedBy { get; init; }
    public string? CreatedByName { get; init; }
}
