using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Receipts;

/* ── payment methods ───────────────────────────────────────────────────────────────────────── */

/// <summary>A way a customer pays: Cash, Bank Transfer, Cheque, and whatever else the business adds.</summary>
public class PaymentMethodDto
{
    public int Id { get; init; }
    public string MethodCode { get; init; } = string.Empty;
    public string MethodName { get; init; } = string.Empty;
    public string? Description { get; init; }
    public bool IsActive { get; init; }

    /// <summary>Receipt lines using the method. Only the list computes it; a single read leaves it 0.</summary>
    public int UsedCount { get; init; }

    public DateTime CreatedAtUtc { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

public sealed class PaymentMethodLookupDto
{
    public int Id { get; init; }
    public string MethodCode { get; init; } = string.Empty;
    public string MethodName { get; init; } = string.Empty;
    public bool IsActive { get; init; }
}

public sealed class PaymentMethodQuery
{
    public string? Search { get; init; }
    public bool? IsActive { get; init; }

    /// <summary>MethodCode, MethodName or IsActive.</summary>
    public string SortBy { get; init; } = "MethodCode";

    public string SortDir { get; init; } = "asc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}

public sealed class SavePaymentMethodRequest
{
    [Required]
    [StringLength(10, MinimumLength = 1)]
    public string MethodCode { get; init; } = string.Empty;

    [Required]
    [StringLength(100, MinimumLength = 1)]
    public string MethodName { get; init; } = string.Empty;

    [StringLength(500)]
    public string? Description { get; init; }

    public bool IsActive { get; init; } = true;
    public string? RowVersion { get; init; }
}

/* ── cash and bank accounts ────────────────────────────────────────────────────────────────── */

/// <summary>The cash boxes and bank accounts a receipt line says the money went into.</summary>
public static class CashBankAccountTypes
{
    public const string Cash = "Cash";
    public const string Bank = "Bank";
}

/// <summary>An account holds ONE currency, which is why a receipt line's account must match the line's.</summary>
public class CashBankAccountDto
{
    public int Id { get; init; }
    public string AccountCode { get; init; } = string.Empty;
    public string AccountName { get; init; } = string.Empty;

    /// <summary>Cash or Bank.</summary>
    public string AccountType { get; init; } = CashBankAccountTypes.Cash;

    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;

    /// <summary>Null = usable from every branch.</summary>
    public int? BranchId { get; init; }

    public string? BranchName { get; init; }
    public string? Description { get; init; }
    public bool IsActive { get; init; }

    /// <summary>Receipt lines using the account. Only the list computes it; a single read leaves it 0.</summary>
    public int UsedCount { get; init; }

    public DateTime CreatedAtUtc { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

public sealed class CashBankAccountLookupDto
{
    public int Id { get; init; }
    public string AccountCode { get; init; } = string.Empty;
    public string AccountName { get; init; } = string.Empty;
    public string AccountType { get; init; } = CashBankAccountTypes.Cash;
    public int CurrencyId { get; init; }
    public string CurrencyCode { get; init; } = string.Empty;
    public int? BranchId { get; init; }
    public bool IsActive { get; init; }
}

public sealed class CashBankAccountQuery
{
    public string? Search { get; init; }

    /// <summary>Cash or Bank.</summary>
    public string? AccountType { get; init; }

    public int? CurrencyId { get; init; }
    public bool? IsActive { get; init; }

    /// <summary>AccountCode, AccountName, AccountType, CurrencyCode or IsActive.</summary>
    public string SortBy { get; init; } = "AccountCode";

    public string SortDir { get; init; } = "asc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}

public sealed class SaveCashBankAccountRequest
{
    [Required]
    [StringLength(20, MinimumLength = 1)]
    public string AccountCode { get; init; } = string.Empty;

    [Required]
    [StringLength(100, MinimumLength = 1)]
    public string AccountName { get; init; } = string.Empty;

    /// <summary>Cash or Bank.</summary>
    [Required]
    [RegularExpression("^(Cash|Bank)$", ErrorMessage = "Account type must be Cash or Bank.")]
    public string AccountType { get; init; } = CashBankAccountTypes.Cash;

    [Range(1, int.MaxValue)]
    public int CurrencyId { get; init; }

    [Range(1, int.MaxValue)]
    public int? BranchId { get; init; }

    [StringLength(500)]
    public string? Description { get; init; }

    public bool IsActive { get; init; } = true;
    public string? RowVersion { get; init; }
}

/// <summary>Body of set-active on either list.</summary>
public sealed class SetReceiptMasterActiveRequest
{
    public bool IsActive { get; init; }
    public string? RowVersion { get; init; }
}
