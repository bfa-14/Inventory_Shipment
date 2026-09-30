namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Public view of a party, with the names of the records it points at joined in.</summary>
public sealed class PartyDto
{
    public int Id { get; init; }
    public string PartyCode { get; init; } = string.Empty;
    public string PartyName { get; init; } = string.Empty;

    public bool IsSupplier { get; init; }
    public bool IsClient { get; init; }
    public bool IsSalesman { get; init; }
    public bool IsEmployee { get; init; }

    public int? BranchId { get; init; }

    /// <summary>Read-only, joined from the branch.</summary>
    public string? BranchCode { get; init; }

    /// <summary>Read-only, joined from the branch.</summary>
    public string? BranchName { get; init; }

    public string? ContactPerson { get; init; }
    public string? Phone { get; init; }
    public string? Mobile { get; init; }
    public string? Email { get; init; }
    public string? Address { get; init; }

    /// <summary>ISO 3166-1 alpha-2 country code, e.g. "IN".</summary>
    public string? Country { get; init; }

    public string? TaxRegistrationNo { get; init; }
    public string? Notes { get; init; }

    /// <summary>The application user this party signs in as, when there is one.</summary>
    public int? UserId { get; init; }

    /// <summary>Read-only, joined from the linked user.</summary>
    public string? UserName { get; init; }

    /// <summary>Read-only, joined from the linked user.</summary>
    public string? UserFullName { get; init; }

    /// <summary>The price list pre-filled on this party's invoices; editable there.</summary>
    public int? DefaultPriceListId { get; init; }

    /// <summary>Read-only, joined from the default price list.</summary>
    public string? DefaultPriceListName { get; init; }

    public int? DefaultCurrencyId { get; init; }

    /// <summary>Read-only, joined from the default currency.</summary>
    public string? DefaultCurrencyCode { get; init; }

    public bool IsActive { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }

    /// <summary>The row's ROWVERSION as Base64. Send it back on update to detect concurrent edits.</summary>
    public string RowVersion { get; init; } = string.Empty;
}

/// <summary>A party as it appears in a dropdown, with what choosing it should default to.</summary>
public sealed class PartyLookupDto
{
    public int Id { get; init; }
    public string PartyCode { get; init; } = string.Empty;
    public string PartyName { get; init; } = string.Empty;
    public bool IsSupplier { get; init; }
    public bool IsClient { get; init; }
    public bool IsSalesman { get; init; }
    public bool IsEmployee { get; init; }
    public int? BranchId { get; init; }
    public int? DefaultPriceListId { get; init; }
    public int? DefaultCurrencyId { get; init; }
    public int? UserId { get; init; }
    public bool IsActive { get; init; }

    /// <summary>The party's address as Parties holds it, so a document header can show it.</summary>
    public string? Address { get; init; }
}
