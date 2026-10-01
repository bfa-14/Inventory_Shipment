namespace Inventory_Shipment.Model.DTOs.Receipts;

/// <summary>
/// One customer's account as a ledger in the base currency: invoices and reversed receipts add to
/// what is owed, receipts, returns and cancelled invoices take from it.
/// </summary>
public sealed class CustomerStatementDto
{
    public int ClientId { get; init; }
    public string ClientCode { get; init; } = string.Empty;
    public string ClientName { get; init; } = string.Empty;
    public string? BaseCurrencyCode { get; init; }

    /// <summary>The balance before the first entry shown: what was owed when the period began.</summary>
    public decimal OpeningBalance { get; init; }

    public decimal TotalDebit => Entries.Sum(e => e.Debit);
    public decimal TotalCredit => Entries.Sum(e => e.Credit);

    /// <summary>What is owed at the end of the period. Positive: the customer owes us.</summary>
    public decimal ClosingBalance => OpeningBalance + TotalDebit - TotalCredit;

    public IReadOnlyList<CustomerStatementEntryDto> Entries { get; init; } = [];
}

public sealed class CustomerStatementEntryDto
{
    public DateTime EntryDate { get; init; }

    /// <summary>Invoice, Invoice cancelled, Sales return, Receipt or Receipt reversed.</summary>
    public string EntryType { get; init; } = string.Empty;

    public int DocumentId { get; init; }
    public string? DocumentNumber { get; init; }

    /// <summary>The document's own currency; its amount is <see cref="DocAmount"/>.</summary>
    public string? CurrencyCode { get; init; }

    public int DecimalPlaces { get; init; }
    public decimal DocAmount { get; init; }
    public decimal Debit { get; init; }
    public decimal Credit { get; init; }

    /// <summary>The running balance, continued from the history before the period.</summary>
    public decimal Balance { get; init; }
}
