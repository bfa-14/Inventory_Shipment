using Inventory_Shipment.Model.DTOs.Messaging;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>One email to send now (the outbox worker's emails, and the settings page's test).</summary>
public sealed record OutgoingEmail(
    string To, string? Cc, string Subject, string HtmlBody, EmailAttachment? Attachment = null);

/// <summary>
/// The mail server refused or could not be reached. <see cref="Exception.Message"/> is written for a person
/// ("Cannot reach smtp.example.com:587. Check the server name, the port and the firewall.") and never
/// contains a password.
/// </summary>
public sealed class EmailSendException : Exception
{
    public EmailSendException(string message, Exception? inner = null) : base(message, inner)
    {
    }
}

/// <summary>Sends one email over SMTP with the given settings, at once (no queue).</summary>
public interface IEmailSender
{
    /// <exception cref="EmailSendException">Any failure, with a readable message.</exception>
    Task SendAsync(OutgoingEmail email, EffectiveEmailSettings settings, CancellationToken cancellationToken = default);
}
