using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>Body of both POST (create) and PUT (update) on a party.</summary>
public sealed class SavePartyRequest
{
    /// <summary>
    /// Unique code, never renamed once transactions point at it. GET next-code suggests one from the
    /// first checked type (SUP-0001, CLI-0001...); the user may replace it before saving.
    /// </summary>
    [Required]
    [StringLength(20, MinimumLength = 1)]
    public string PartyCode { get; init; } = string.Empty;

    [Required]
    [StringLength(200, MinimumLength = 1)]
    public string PartyName { get; init; } = string.Empty;

    // The four type flags are independent - a company can be both a supplier and a client. At least
    // one must be set; the service checks that (a data annotation cannot span four properties).
    public bool IsSupplier { get; init; }
    public bool IsClient { get; init; }
    public bool IsSalesman { get; init; }
    public bool IsEmployee { get; init; }

    /// <summary>Home branch. Must be an active branch when supplied.</summary>
    public int? BranchId { get; init; }

    [StringLength(150)]
    public string? ContactPerson { get; init; }

    [StringLength(50)]
    public string? Phone { get; init; }

    [StringLength(50)]
    public string? Mobile { get; init; }

    [EmailAddress]
    [StringLength(150)]
    public string? Email { get; init; }

    [StringLength(500)]
    public string? Address { get; init; }

    /// <summary>ISO 3166-1 alpha-2 country code, e.g. "IN". Stored upper-case.</summary>
    [RegularExpression("^[A-Za-z]{2}$", ErrorMessage = "Country must be a 2-letter ISO country code (e.g. IN).")]
    public string? Country { get; init; }

    [StringLength(50)]
    public string? TaxRegistrationNo { get; init; }

    [StringLength(1000)]
    public string? Notes { get; init; }

    /// <summary>
    /// The application user this party signs in as (salesman / employee). One party per user:
    /// linking a user already taken fails with code USER_ALREADY_LINKED.
    /// </summary>
    public int? UserId { get; init; }

    /// <summary>
    /// Clients: the price list applied when this party buys. Must be an active price list, and only
    /// accepted when <see cref="IsClient"/> is set.
    /// </summary>
    public int? ClientPriceListId { get; init; }

    /// <summary>
    /// Salesmen: the price list this person sells with. Must be an active price list, and only
    /// accepted when <see cref="IsSalesman"/> is set.
    /// </summary>
    public int? SalesmanPriceListId { get; init; }

    /// <summary>Suppliers: the currency purchases default to. Must be an active currency when supplied.</summary>
    public int? DefaultCurrencyId { get; init; }

    public bool IsActive { get; init; } = true;

    /// <summary>Base64 ROWVERSION read with the party (update only). Null skips the concurrency check.</summary>
    public string? RowVersion { get; init; }
}
