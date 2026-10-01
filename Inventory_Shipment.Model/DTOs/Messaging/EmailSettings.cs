using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Messaging;

/// <summary>How the connection to the mail server is secured (messaging.EmailSettings.SmtpSecurity).</summary>
public static class SmtpSecurityModes
{
    public const byte None = 0;

    /// <summary>Plain connection upgraded with STARTTLS - port 587, what Gmail and Microsoft 365 expect.</summary>
    public const byte StartTls = 1;

    /// <summary>TLS from the first byte - port 465.</summary>
    public const byte SslOnConnect = 2;
}

/// <summary>
/// Settings > Email as the page shows it. THE PASSWORD IS NEVER HERE: only whether one is saved
/// (<see cref="HasPassword"/>) and whether it can still be decrypted (<see cref="PasswordUnreadable"/>).
/// </summary>
public sealed class EmailSettingsDto
{
    /// <summary>False until the page saves once: emails are not sent before.</summary>
    public bool IsSaved { get; init; }

    public bool SendingEnabled { get; init; }
    public string? SmtpHost { get; init; }
    public int SmtpPort { get; init; }

    /// <summary>0 none, 1 STARTTLS, 2 SSL/TLS.</summary>
    public byte SmtpSecurity { get; init; }

    public string? SmtpUserName { get; init; }
    public bool HasPassword { get; init; }

    /// <summary>A password is saved but the keys that encrypted it are gone: it must be typed again.</summary>
    public bool PasswordUnreadable { get; init; }

    public string? FromAddress { get; init; }
    public string? FromName { get; init; }
    public string? ReplyToAddress { get; init; }

    /// <summary>The address typed on the page (may be empty).</summary>
    public string? PublicBaseUrl { get; init; }

    /// <summary>The address the links really use: the page's, else App:PublicBaseUrl of the configuration.</summary>
    public string? EffectivePublicBaseUrl { get; init; }

    public DateTime? LastTestAtUtc { get; init; }
    public bool? LastTestOk { get; init; }
    public string? LastTestError { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public string? UpdatedByName { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

/// <summary>The fields of the page that describe a mail server - what a save stores and what a test tries.</summary>
public class EmailSettingsValues
{
    public bool SendingEnabled { get; init; }

    [StringLength(200)]
    public string? SmtpHost { get; init; }

    public int SmtpPort { get; init; } = 587;

    /// <summary>0 none, 1 STARTTLS, 2 SSL/TLS.</summary>
    public byte SmtpSecurity { get; init; } = SmtpSecurityModes.StartTls;

    [StringLength(256)]
    public string? SmtpUserName { get; init; }

    /// <summary>Typed in the form; null or "" = keep (or, for a test, use) the saved password.</summary>
    [StringLength(512)]
    public string? Password { get; init; }

    [StringLength(256)]
    public string? FromAddress { get; init; }

    [StringLength(200)]
    public string? FromName { get; init; }

    [StringLength(256)]
    public string? ReplyToAddress { get; init; }

    [StringLength(300)]
    public string? PublicBaseUrl { get; init; }
}

public sealed class SaveEmailSettingsRequest : EmailSettingsValues
{
    /// <summary>True removes the saved password (Password is then ignored).</summary>
    public bool RemovePassword { get; init; }

    public string? RowVersion { get; init; }
}

/// <summary>"Send test email": to one address, with the values on the screen or, without them, the saved settings.</summary>
public sealed class TestEmailSettingsRequest
{
    [Required]
    [StringLength(256)]
    public string To { get; init; } = string.Empty;

    public EmailSettingsValues? Values { get; init; }
}

public sealed class EmailTestResultDto
{
    public bool Ok { get; init; }

    /// <summary>Readable: what to check (the server, the port, the password...). Null when it worked.</summary>
    public string? Error { get; init; }

    public long DurationMs { get; init; }

    /// <summary>The settings row's new version: recording the result changes it, and the page's next save needs it.</summary>
    public byte[] RowVersion { get; init; } = [];
}

/// <summary>messaging.usp_EmailSettings_Get - the saved row without the password.</summary>
public sealed class EmailSettingsRow
{
    public bool SendingEnabled { get; init; }
    public string? SmtpHost { get; init; }
    public int SmtpPort { get; init; }
    public byte SmtpSecurity { get; init; }
    public string? SmtpUserName { get; init; }
    public string? FromAddress { get; init; }
    public string? FromName { get; init; }
    public string? ReplyToAddress { get; init; }
    public string? PublicBaseUrl { get; init; }
    public DateTime? LastTestAtUtc { get; init; }
    public bool? LastTestOk { get; init; }
    public string? LastTestError { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public int? UpdatedBy { get; init; }
    public byte[] RowVersion { get; init; } = [];
    public bool HasPassword { get; init; }
    public bool IsSaved { get; init; }
    public string? UpdatedByName { get; init; }
}

/// <summary>messaging.usp_EmailSettings_GetForSending - the saved row WITH the encrypted password. Read by the API only.</summary>
public sealed class EmailSettingsSendingRow
{
    public bool SendingEnabled { get; init; }
    public string? SmtpHost { get; init; }
    public int SmtpPort { get; init; }
    public byte SmtpSecurity { get; init; }
    public string? SmtpUserName { get; init; }
    public string? SmtpPasswordProtected { get; init; }
    public string? FromAddress { get; init; }
    public string? FromName { get; init; }
    public string? ReplyToAddress { get; init; }
    public string? PublicBaseUrl { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

/// <summary>What messaging.usp_EmailSettings_Save stores. 0 keeps the saved password, 1 replaces it, 2 removes it.</summary>
public sealed record EmailSettingsSave(
    bool SendingEnabled, string? SmtpHost, int SmtpPort, byte SmtpSecurity, string? SmtpUserName,
    byte PasswordAction, string? SmtpPasswordProtected,
    string? FromAddress, string? FromName, string? ReplyToAddress, string? PublicBaseUrl,
    byte[]? RowVersion, int UserId);
