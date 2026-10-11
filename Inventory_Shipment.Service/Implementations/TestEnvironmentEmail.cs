using System.Diagnostics.CodeAnalysis;
using System.Net;
using System.Text.RegularExpressions;
using Inventory_Shipment.Service.Interfaces;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// The emails of the testing environment (App:Environment = "testing"): its database is usually a copy of
/// production, so what its outbox sends must never reach the suppliers and approvers written in it.
///
/// ONE ADDRESS RECEIVES EVERYTHING: the email goes to App:TestEmailRedirectTo only, never to a Cc, with
/// "[TEST] " before the subject and a visible note on top naming the recipients it was written for. The
/// attachment is kept, so the tester sees exactly what the supplier would get. The decision to send at all
/// is the outbox worker's; this class only reads and rewrites the email.
/// </summary>
public static partial class TestEnvironmentEmail
{
    public const string SubjectPrefix = "[TEST] ";

    /// <summary>One valid address, by the same rule as every address the application sends to.</summary>
    public static bool IsValidRedirect([NotNullWhen(true)] string? address) => EmailAddresses.IsValid(address);

    /// <summary>The same email, for <paramref name="redirectTo"/> alone.</summary>
    public static OutgoingEmail Redirect(OutgoingEmail email, string redirectTo)
        => email with
        {
            To = redirectTo,
            Cc = null,
            Subject = SubjectPrefix + email.Subject,
            HtmlBody = WithNote(email.HtmlBody, Note(email)),
        };

    /// <summary>
    /// The origin (https://host[:port]) of the first link of <paramref name="html"/> that does not open
    /// <paramref name="publicBaseUrl"/>, this environment's address; null when every link opens it, or there is none.
    ///
    /// A LINK ELSEWHERE MEANS ANOTHER ENVIRONMENT WROTE THE EMAIL: the outbox stores finished HTML, so the copy
    /// of production that testing runs on holds production's unsent emails, whose approval links open production
    /// with tokens valid there. Sent to a tester, one click would approve a real order as the real approver.
    /// Testing builds every link of its own emails from its own address (<see cref="WebRoutes"/>), so nothing
    /// else is caught. Only the origin comes back: the rest of a link can be a personal token, never logged.
    /// </summary>
    public static string? ForeignLinkOrigin(string html, string? publicBaseUrl)
    {
        foreach (Match match in Href().Matches(html))
        {
            var url = WebUtility.HtmlDecode(match.Groups["url"].Value).Trim();

            // mailto:, anchors and relative links lead to no environment (a relative path parses as file:// on Linux).
            if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)
                || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
            {
                continue;
            }

            var own = publicBaseUrl is not null
                      && (url.Equals(publicBaseUrl, StringComparison.OrdinalIgnoreCase)
                          || url.StartsWith(publicBaseUrl + "/", StringComparison.OrdinalIgnoreCase)
                          || url.StartsWith(publicBaseUrl + "?", StringComparison.OrdinalIgnoreCase));
            if (!own)
            {
                return $"{uri.Scheme}://{uri.Authority}";
            }
        }

        return null;
    }

    /// <summary>
    /// Every value HTML-encoded. Plain inline styles, like the purchase emails: the mail clients drop
    /// &lt;style&gt; blocks. The plain-text part the sender derives from the HTML carries the note too, which
    /// is why the note has no line break of its own between the &lt;br&gt;s (each would add a blank line there).
    /// </summary>
    private static string Note(OutgoingEmail email)
        => """<div style="margin:0;padding:12px 16px;background:#fff3bf;border:2px solid #f08c00;"""
           + """font-family:'Segoe UI',Arial,Helvetica,sans-serif;font-size:13px;line-height:1.5;color:#1f2937;">"""
           + "<strong>TEST EMAIL from the testing environment.</strong> It was not sent to its real recipients.<br>"
           + $"Original To: {E(List(email.To))}<br>"
           + $"Original Cc: {E(List(email.Cc))}</div>";

    /// <summary>Right after the opening &lt;body&gt; of a whole page, else at the very top of a fragment.</summary>
    private static string WithNote(string html, string note)
    {
        var body = BodyTag().Match(html);
        return body.Success
            ? html.Insert(body.Index + body.Length, "\n" + note)
            : note + "\n" + html;
    }

    private static string List(string? addresses)
    {
        var list = EmailAddresses.Split(addresses);
        return list.Count == 0 ? "none" : string.Join("; ", list);
    }

    private static string E(string text) => WebUtility.HtmlEncode(text);

    [GeneratedRegex(@"<body\b[^>]*>", RegexOptions.IgnoreCase)]
    private static partial Regex BodyTag();

    [GeneratedRegex("""\bhref\s*=\s*(?:"(?<url>[^"]*)"|'(?<url>[^']*)')""", RegexOptions.IgnoreCase)]
    private static partial Regex Href();
}
