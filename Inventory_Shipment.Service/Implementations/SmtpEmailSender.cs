using System.Net;
using System.Net.Sockets;
using System.Text.RegularExpressions;
using Inventory_Shipment.Service.Interfaces;
using MailKit;
using MailKit.Net.Smtp;
using MailKit.Security;
using MimeKit;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// MailKit over SMTP: one connection per email, 20 seconds at most from connect to disconnect.
///
/// THE ERRORS ARE TRANSLATED HERE, once, for the outbox log and for the settings page's test alike:
/// the person reading them is choosing between "wrong password", "wrong server or port" and "wrong
/// security option", and MailKit's own text names a protocol state instead. No message ever carries
/// the password - MailKit does not put it in its exceptions, and nothing here adds it.
/// </summary>
public sealed partial class SmtpEmailSender : IEmailSender
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(20);

    public async Task SendAsync(OutgoingEmail email, EffectiveEmailSettings settings, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(settings.Host))
        {
            throw new EmailSendException("Enter the mail server in Settings > Email first.");
        }

        var from = settings.FromAddress;
        if (!EmailAddresses.IsValid(from))
        {
            throw new EmailSendException("Enter a valid sender address in Settings > Email first.");
        }

        var message = Build(email, settings, from);

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(Timeout);
        using var client = new SmtpClient { Timeout = (int)Timeout.TotalMilliseconds };

        try
        {
            var security = settings.Security switch
            {
                SmtpSecurity.None => SecureSocketOptions.None,
                SmtpSecurity.SslOnConnect => SecureSocketOptions.SslOnConnect,
                _ => SecureSocketOptions.StartTls,
            };

            await client.ConnectAsync(settings.Host, settings.Port, security, timeout.Token);
            if (!string.IsNullOrWhiteSpace(settings.UserName))
            {
                await client.AuthenticateAsync(settings.UserName, settings.Password ?? string.Empty, timeout.Token);
            }

            await client.SendAsync(message, timeout.Token);
            await client.DisconnectAsync(true, timeout.Token);
        }
        catch (Exception ex) when (ex is not EmailSendException && !(ex is OperationCanceledException && cancellationToken.IsCancellationRequested))
        {
            throw new EmailSendException(Describe(ex, settings), ex);
        }
    }

    private static MimeMessage Build(OutgoingEmail email, EffectiveEmailSettings settings, string from)
    {
        var message = new MimeMessage();
        message.From.Add(new MailboxAddress(string.IsNullOrWhiteSpace(settings.FromName) ? from : settings.FromName, from));
        var replyTo = settings.ReplyTo;
        if (EmailAddresses.IsValid(replyTo))
        {
            message.ReplyTo.Add(MailboxAddress.Parse(replyTo));
        }

        foreach (var address in EmailAddresses.Split(email.To))
        {
            message.To.Add(Mailbox(address));
        }

        foreach (var address in EmailAddresses.Split(email.Cc))
        {
            message.Cc.Add(Mailbox(address));
        }

        if (message.To.Count == 0)
        {
            throw new EmailSendException("The email has no recipient.");
        }

        message.Subject = email.Subject;

        // HTML for the people, a plain-text alternative for the mail clients and spam filters that look for one.
        var body = new BodyBuilder { HtmlBody = email.HtmlBody, TextBody = ToPlainText(email.HtmlBody) };
        if (email.Attachment is not null)
        {
            body.Attachments.Add(email.Attachment.FileName, email.Attachment.Content, ContentType.Parse(email.Attachment.ContentType));
        }

        message.Body = body.ToMessageBody();
        return message;
    }

    private static MailboxAddress Mailbox(string address)
        => EmailAddresses.IsValid(address)
            ? MailboxAddress.Parse(address)
            : throw new EmailSendException($"Not a valid email address: {address}");

    /// <summary>What the person who reads the log or the test result should check.</summary>
    private static string Describe(Exception exception, EffectiveEmailSettings settings)
    {
        var place = $"{settings.Host}:{settings.Port}";
        return exception switch
        {
            AuthenticationException =>
                "The server refused the user name or password. Gmail needs an app password; Microsoft 365 needs SMTP AUTH enabled for this mailbox.",
            SslHandshakeException =>
                "The secure connection failed: use STARTTLS with port 587, or SSL/TLS with port 465.",
            SocketException or TimeoutException or OperationCanceledException or IOException =>
                $"Cannot reach {place}. Check the server name, the port and the firewall.",
            ServiceNotConnectedException =>
                $"Cannot reach {place}. Check the server name, the port and the firewall.",
            NotSupportedException when exception.Message.Contains("STARTTLS", StringComparison.OrdinalIgnoreCase) =>
                "The secure connection failed: use STARTTLS with port 587, or SSL/TLS with port 465.",
            SmtpCommandException command when command.StatusCode == SmtpStatusCode.AuthenticationRequired =>
                "The server needs a user name and a password.",
            _ => exception.Message,
        };
    }

    /// <summary>A readable text version of an HTML email: blocks on their own lines, tags removed, entities decoded.</summary>
    internal static string ToPlainText(string html)
    {
        var text = HiddenBlocks().Replace(html, string.Empty);
        text = LineBreaks().Replace(text, "\n");
        text = Tags().Replace(text, string.Empty);
        text = WebUtility.HtmlDecode(text);
        var lines = text.Split('\n').Select(line => Spaces().Replace(line, " ").Trim());
        return ManyBlankLines().Replace(string.Join('\n', lines), "\n\n").Trim();
    }

    [GeneratedRegex(@"<(style|script|head)\b[^>]*>.*?</\1>", RegexOptions.IgnoreCase | RegexOptions.Singleline)]
    private static partial Regex HiddenBlocks();

    [GeneratedRegex(@"<br\s*/?>|</(p|div|tr|h[1-6]|li|table)>", RegexOptions.IgnoreCase)]
    private static partial Regex LineBreaks();

    [GeneratedRegex(@"<[^>]+>")]
    private static partial Regex Tags();

    [GeneratedRegex(@"[ \t\r\f\v]+")]
    private static partial Regex Spaces();

    [GeneratedRegex(@"\n{3,}")]
    private static partial Regex ManyBlankLines();
}
