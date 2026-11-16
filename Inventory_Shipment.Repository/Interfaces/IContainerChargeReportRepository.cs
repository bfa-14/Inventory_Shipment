using Inventory_Shipment.Model.DTOs.Reports;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>The Container Charges Report's reads (script 105): the service adds the charges up per container and type.</summary>
public interface IContainerChargeReportRepository
{
    /// <summary>reporting.usp_ContainerChargeReport: the containers, the charges of the types asked, the types asked.</summary>
    Task<ContainerChargeReportData> DataAsync(
        IReadOnlyCollection<int> chargeTypeIds, string dateBasis, DateOnly? dateFrom, DateOnly? dateTo, string? search,
        int? supplierId, CancellationToken cancellationToken = default);

    /// <summary>The filters' lists: every charge type, and the suppliers of containers' orders.</summary>
    Task<ContainerChargeReportOptions> OptionsAsync(CancellationToken cancellationToken = default);

    /// <summary>The base currency's code (masterdata.Currencies.IsBaseCurrency).</summary>
    Task<string?> BaseCurrencyCodeAsync(CancellationToken cancellationToken = default);
}

public sealed class ContainerChargeReportData
{
    public IReadOnlyList<ContainerChargeContainerRow> Containers { get; init; } = [];
    public IReadOnlyList<ContainerChargeRow> Charges { get; init; } = [];
    public IReadOnlyList<ContainerChargeTypeDto> ChargeTypes { get; init; } = [];
}

public sealed class ContainerChargeContainerRow
{
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public string? BlNo { get; init; }
    public byte ContainerStatus { get; init; }
    public string? Items { get; init; }
    public int Pieces { get; init; }
    public string? Suppliers { get; init; }
    public string? Orders { get; init; }
    public string? FinalDestination { get; init; }
    public int StageSort { get; init; }
    public string StageLabel { get; init; } = string.Empty;
    public DateTime? DispatchDate { get; init; }
    public DateTime? OffloadedDate { get; init; }
    public string? BranchName { get; init; }
    public string? WarehouseName { get; init; }
}

public sealed class ContainerChargeRow
{
    public int ChargeId { get; init; }
    public int ContainerId { get; init; }
    public int ChargeTypeId { get; init; }
    public byte Status { get; init; }
    public DateTime ChargeDate { get; init; }
    public string? Reference { get; init; }
    public string? ProviderName { get; init; }
    public string? CurrencyCode { get; init; }
    public decimal Amount { get; init; }
    public decimal AmountBase { get; init; }
    public decimal PaidAmount { get; init; }
    public decimal PaidBase { get; init; }
    public string? Payments { get; init; }
}
