using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Logistics;

/* The three lists the container pages pick from: container types (with the capacity copied onto a
   new container), ports and places, and the attachment types of the container files. Same five
   verbs each; a used row is deactivated rather than deleted (69014 IN_USE). */

/* ── container types ───────────────────────────────────────────────────────────────────────── */

public class ContainerTypeDto
{
    public int Id { get; init; }
    public string TypeCode { get; init; } = string.Empty;
    public string TypeName { get; init; } = string.Empty;

    /// <summary>Default capacity in BASE units, copied onto a new container and editable there.</summary>
    public int? MaxUnits { get; init; }

    public decimal? MaxWeightKg { get; init; }
    public decimal? MaxVolumeCbm { get; init; }
    public string? Description { get; init; }
    public bool IsActive { get; init; }

    /// <summary>Containers using the type. Only the list computes it; a single read leaves it 0.</summary>
    public int UsedCount { get; init; }

    public DateTime CreatedAtUtc { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

public sealed class ContainerTypeLookupDto
{
    public int Id { get; init; }
    public string TypeCode { get; init; } = string.Empty;
    public string TypeName { get; init; } = string.Empty;
    public int? MaxUnits { get; init; }
    public decimal? MaxWeightKg { get; init; }
    public decimal? MaxVolumeCbm { get; init; }
    public bool IsActive { get; init; }
}

public sealed class ContainerTypeQuery
{
    public string? Search { get; init; }
    public bool? IsActive { get; init; }

    /// <summary>TypeCode, TypeName, MaxUnits or IsActive.</summary>
    public string SortBy { get; init; } = "TypeCode";

    public string SortDir { get; init; } = "asc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}

public sealed class SaveContainerTypeRequest
{
    [Required]
    [StringLength(10, MinimumLength = 1)]
    public string TypeCode { get; init; } = string.Empty;

    [Required]
    [StringLength(100, MinimumLength = 1)]
    public string TypeName { get; init; } = string.Empty;

    [Range(1, int.MaxValue)]
    public int? MaxUnits { get; init; }

    [Range(0.001, 999999999999.999)]
    public decimal? MaxWeightKg { get; init; }

    [Range(0.001, 999999999999.999)]
    public decimal? MaxVolumeCbm { get; init; }

    [StringLength(500)]
    public string? Description { get; init; }

    public bool IsActive { get; init; } = true;
    public string? RowVersion { get; init; }
}

/* ── ports and places ──────────────────────────────────────────────────────────────────────── */

public static class PortKinds
{
    public static readonly string[] All = ["Sea", "Inland", "Border", "Air"];

    public static string? Normalize(string? kind)
        => All.FirstOrDefault(k => string.Equals(k, kind, StringComparison.OrdinalIgnoreCase));
}

public class PortDto
{
    public int Id { get; init; }
    public string PortCode { get; init; } = string.Empty;
    public string PortName { get; init; } = string.Empty;
    public string? CountryCode { get; init; }

    /// <summary>Sea, Inland, Border or Air.</summary>
    public string Kind { get; init; } = "Sea";

    public bool IsActive { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

public sealed class PortLookupDto
{
    public int Id { get; init; }
    public string PortCode { get; init; } = string.Empty;
    public string PortName { get; init; } = string.Empty;
    public string? CountryCode { get; init; }
    public string Kind { get; init; } = "Sea";
    public bool IsActive { get; init; }
}

public sealed class PortQuery
{
    public string? Search { get; init; }

    /// <summary>Sea, Inland, Border or Air.</summary>
    public string? Kind { get; init; }

    public bool? IsActive { get; init; }

    /// <summary>PortCode, PortName, CountryCode, Kind or IsActive.</summary>
    public string SortBy { get; init; } = "PortCode";

    public string SortDir { get; init; } = "asc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}

public sealed class SavePortRequest : IValidatableObject
{
    [Required]
    [StringLength(10, MinimumLength = 1)]
    public string PortCode { get; init; } = string.Empty;

    [Required]
    [StringLength(100, MinimumLength = 1)]
    public string PortName { get; init; } = string.Empty;

    /// <summary>ISO 3166 alpha-2.</summary>
    [StringLength(2, MinimumLength = 2)]
    public string? CountryCode { get; init; }

    [Required]
    [StringLength(10)]
    public string Kind { get; init; } = "Sea";

    public bool IsActive { get; init; } = true;
    public string? RowVersion { get; init; }

    public IEnumerable<ValidationResult> Validate(ValidationContext validationContext)
    {
        if (PortKinds.Normalize(Kind) is null)
        {
            yield return new ValidationResult("Kind must be Sea, Inland, Border or Air.", [nameof(Kind)]);
        }
    }
}

/* ── attachment types ──────────────────────────────────────────────────────────────────────── */

public class AttachmentTypeDto
{
    public int Id { get; init; }

    /// <summary>Container, Purchase, Shipping, Customs, Transport, Delivery or Other — free text, grouped on.</summary>
    public string Category { get; init; } = string.Empty;

    public string SubType { get; init; } = string.Empty;
    public int SortOrder { get; init; }
    public bool IsActive { get; init; }
    public DateTime CreatedAtUtc { get; init; }
    public DateTime? UpdatedAtUtc { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

public sealed class AttachmentTypeLookupDto
{
    public int Id { get; init; }
    public string Category { get; init; } = string.Empty;
    public string SubType { get; init; } = string.Empty;

    /// <summary>"Shipping / Bill of Lading".</summary>
    public string DisplayName { get; init; } = string.Empty;

    public int SortOrder { get; init; }
    public bool IsActive { get; init; }
}

public sealed class AttachmentTypeQuery
{
    public string? Search { get; init; }
    public string? Category { get; init; }
    public bool? IsActive { get; init; }

    /// <summary>SortOrder, Category, SubType or IsActive.</summary>
    public string SortBy { get; init; } = "SortOrder";

    public string SortDir { get; init; } = "asc";
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 10;
}

public sealed class SaveAttachmentTypeRequest
{
    [Required]
    [StringLength(30, MinimumLength = 1)]
    public string Category { get; init; } = string.Empty;

    [Required]
    [StringLength(60, MinimumLength = 1)]
    public string SubType { get; init; } = string.Empty;

    public int SortOrder { get; init; }
    public bool IsActive { get; init; } = true;
    public string? RowVersion { get; init; }
}

/// <summary>Activate / deactivate one row of any of the three lists.</summary>
public sealed class SetLogisticsMasterActiveRequest
{
    public bool IsActive { get; init; }
    public string? RowVersion { get; init; }
}
