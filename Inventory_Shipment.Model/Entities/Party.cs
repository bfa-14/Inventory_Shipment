namespace Inventory_Shipment.Model.Entities;

/// <summary>
/// A party (table masterdata.Parties) - the single master behind suppliers, clients, salesmen and
/// employees. The four type flags are independent and at least one of them is set, so the same
/// company can be a supplier and a client without being entered twice. The names of the related
/// records (branch, linked user, default price list, default currency) are joined in by the
/// procedures and are read-only here.
/// </summary>
public class Party
{
    public int Id { get; set; }

    /// <summary>Unique, never renamed. Suggested as SUP-/CLI-/SAL-/EMP- + 4 digits, then editable.</summary>
    public string PartyCode { get; set; } = string.Empty;

    public string PartyName { get; set; } = string.Empty;

    public bool IsSupplier { get; set; }
    public bool IsClient { get; set; }
    public bool IsSalesman { get; set; }
    public bool IsEmployee { get; set; }

    public int? BranchId { get; set; }

    /// <summary>Joined from masterdata.Branches - read-only.</summary>
    public string? BranchCode { get; set; }

    /// <summary>Joined from masterdata.Branches - read-only.</summary>
    public string? BranchName { get; set; }

    public string? ContactPerson { get; set; }
    public string? Phone { get; set; }
    public string? Mobile { get; set; }
    public string? Email { get; set; }
    public string? Address { get; set; }

    /// <summary>ISO 3166-1 alpha-2 country code, e.g. "IN". Stored upper-case.</summary>
    public string? Country { get; set; }

    public string? TaxRegistrationNo { get; set; }
    public string? Notes { get; set; }

    /// <summary>
    /// The application user this party is, when it is a person who signs in (salesman / employee).
    /// At most one party per user, so the system can recognize "the salesman currently signed in".
    /// </summary>
    public int? UserId { get; set; }

    /// <summary>Joined from security.Users - read-only.</summary>
    public string? UserName { get; set; }

    /// <summary>Joined from security.Users - read-only.</summary>
    public string? UserFullName { get; set; }

    /// <summary>
    /// The price list pre-filled on this party's invoices; it stays editable there. Optional and
    /// independent of the type flags - a supplier, a client or a salesman may each carry one.
    /// </summary>
    public int? DefaultPriceListId { get; set; }

    /// <summary>Joined from masterdata.PriceLists - read-only.</summary>
    public string? DefaultPriceListName { get; set; }

    /// <summary>Suppliers: the currency purchases default to.</summary>
    public int? DefaultCurrencyId { get; set; }

    /// <summary>Joined from masterdata.Currencies - read-only.</summary>
    public string? DefaultCurrencyCode { get; set; }

    public bool IsActive { get; set; } = true;
    public DateTime CreatedAtUtc { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? UpdatedAtUtc { get; set; }
    public int? UpdatedBy { get; set; }

    /// <summary>SQL Server ROWVERSION (8 bytes) used for optimistic concurrency.</summary>
    public byte[] RowVersion { get; set; } = [];
}

/// <summary>
/// One row of masterdata.usp_Party_Lookup - just enough to fill a typed dropdown (the suppliers on a
/// purchase order, the clients on an invoice...) and to prefill what the chosen party defaults to.
/// </summary>
public sealed class PartyLookup
{
    public int Id { get; set; }
    public string PartyCode { get; set; } = string.Empty;
    public string PartyName { get; set; } = string.Empty;
    public bool IsSupplier { get; set; }
    public bool IsClient { get; set; }
    public bool IsSalesman { get; set; }
    public bool IsEmployee { get; set; }
    public int? BranchId { get; set; }
    public int? DefaultPriceListId { get; set; }
    public int? DefaultCurrencyId { get; set; }
    public int? UserId { get; set; }
    public bool IsActive { get; set; }
}
