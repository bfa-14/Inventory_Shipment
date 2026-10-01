namespace Inventory_Shipment.Service.Interfaces;

public enum SmtpSecurity
{
    None = 0,
    StartTls = 1,
    SslOnConnect = 2,
}

/// <summary>
/// The mail server settings the application sends with right now: the row saved in Settings > Email, the
/// password decrypted. NEVER SERIALIZED, NEVER LOGGED: <see cref="ToString"/> leaves the password out.
/// </summary>
public sealed class EffectiveEmailSettings
{
    /// <summary>False until Settings > Email is saved once; nothing is sent before.</summary>
    public bool IsSaved { get; init; }

    public bool SendingEnabled { get; init; }
    public string? Host { get; init; }
    public int Port { get; init; } = 587;
    public SmtpSecurity Security { get; init; } = SmtpSecurity.StartTls;
    public string? UserName { get; init; }

    /// <summary>Clear text, in memory only.</summary>
    public string? Password { get; init; }

    public string? FromAddress { get; init; }
    public string? FromName { get; init; }
    public string? ReplyTo { get; init; }

    /// <summary>The address of the web application for the links: the saved one, else App:PublicBaseUrl. No trailing "/".</summary>
    public string? PublicBaseUrl { get; init; }

    /// <summary>A password is saved but can no longer be decrypted (the Data Protection keys were lost).</summary>
    public bool PasswordUnreadable { get; init; }

    public override string ToString()
        => $"{Host}:{Port} ({Security}), user {UserName ?? "-"}, from {FromAddress ?? "-"}, sending {(SendingEnabled ? "on" : "off")}";
}

/// <summary>
/// Reads <see cref="EffectiveEmailSettings"/>, cached for 30 seconds: the outbox worker asks every cycle,
/// every email that builds a link asks, and the row changes a few times a year.
/// </summary>
public interface IEmailSettingsProvider
{
    Task<EffectiveEmailSettings> GetAsync(CancellationToken cancellationToken = default);

    /// <summary>Forgets the cached settings: called by every save, so the next read sees the new values.</summary>
    void Invalidate();
}
