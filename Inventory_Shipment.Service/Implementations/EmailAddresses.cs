using System.Diagnostics.CodeAnalysis;
using MimeKit;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// Lists of addresses as people type them ("a@x.com; b@y.com, c@z.com") and as the outbox stores them
/// (separated by ";").
/// </summary>
internal static class EmailAddresses
{
    private static readonly char[] Separators = [';', ','];

    /// <summary>The non-empty, trimmed addresses of a list, in order, without duplicates (case-insensitive).</summary>
    internal static IReadOnlyList<string> Split(string? list)
        => string.IsNullOrWhiteSpace(list)
            ? []
            : list.Split(Separators, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();

    /// <summary>A single address with a local part, an @ and a domain with a dot, and nothing else.</summary>
    internal static bool IsValid([NotNullWhen(true)] string? address)
        => !string.IsNullOrWhiteSpace(address)
           && !address.Contains(' ')
           && MailboxAddress.TryParse(address, out var mailbox)
           && mailbox.Address == address
           && mailbox.Domain.Contains('.')
           && !mailbox.Domain.StartsWith('.') && !mailbox.Domain.EndsWith('.');

    /// <summary>The outbox's form: the addresses joined by ";", or null when there are none.</summary>
    internal static string? Join(IEnumerable<string> addresses)
    {
        var joined = string.Join(';', addresses);
        return joined.Length == 0 ? null : joined;
    }
}
