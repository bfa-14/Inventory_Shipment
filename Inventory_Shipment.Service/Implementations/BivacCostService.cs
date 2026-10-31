using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;

namespace Inventory_Shipment.Service.Implementations;

/// <summary>
/// BIVAC COSTS PER PORT (script 97). The cost of a BIVAC item at each port of destination, kept on Item Definition,
/// and what a BIVAC charge on some containers costs: each container takes its item's cost at its own port.
/// </summary>
public sealed class BivacCostService : IBivacCostService
{
    private const int MaxContainers = 5000;
    private readonly IBivacCostRepository _repository;

    public BivacCostService(IBivacCostRepository repository)
    {
        _repository = repository;
    }

    public async Task<Result<IReadOnlyList<ItemBivacPortCostDto>>> GetPortCostsAsync(
        int itemId, CancellationToken cancellationToken = default)
        => Result<IReadOnlyList<ItemBivacPortCostDto>>.Success(await _repository.GetPortCostsAsync(itemId, cancellationToken));

    public async Task<Result<IReadOnlyList<ItemBivacPortCostDto>>> SetPortCostsAsync(
        int itemId, SetItemBivacPortCostsRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var costs = request.Costs ?? [];
        if (costs.Any(c => c is null))
        {
            return Result<IReadOnlyList<ItemBivacPortCostDto>>.Failure(ErrorType.Validation, "A cost row of the request is empty.", "VALIDATION");
        }

        if (costs.GroupBy(c => c.PortId).Any(g => g.Count() > 1))
        {
            return Result<IReadOnlyList<ItemBivacPortCostDto>>.Failure(ErrorType.Validation, "Each port once.", "VALIDATION");
        }

        try
        {
            return Result<IReadOnlyList<ItemBivacPortCostDto>>.Success(
                await _repository.SetPortCostsAsync(itemId, costs, userId, cancellationToken));
        }
        catch (BusinessRuleException ex) when (ex.Number == SqlErrors.ItemValidation)
        {
            return Result<IReadOnlyList<ItemBivacPortCostDto>>.Failure(ErrorType.Validation, ex.Message, "VALIDATION");
        }
        catch (BusinessRuleException ex) when (ex.Number == SqlErrors.ItemNotFound)
        {
            return Result<IReadOnlyList<ItemBivacPortCostDto>>.Failure(ErrorType.NotFound, ex.Message, "NOT_FOUND");
        }
    }

    public async Task<Result<BivacChargeOptionsDto>> GetChargeOptionsAsync(
        IReadOnlyCollection<int> containerIds, CancellationToken cancellationToken = default)
    {
        var ids = containerIds.Where(id => id > 0).Distinct().ToList();
        if (ids.Count == 0)
        {
            return Result<BivacChargeOptionsDto>.Failure(ErrorType.Validation, "Choose the containers first.", "VALIDATION");
        }

        if (ids.Count > MaxContainers)
        {
            return Result<BivacChargeOptionsDto>.Failure(
                ErrorType.Validation, $"A BIVAC charge takes at most {MaxContainers:N0} containers.", "VALIDATION");
        }

        return Result<BivacChargeOptionsDto>.Success(await _repository.GetChargeOptionsAsync(ids, cancellationToken));
    }
}
