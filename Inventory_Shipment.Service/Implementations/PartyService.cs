using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.MasterData;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Model.Enums;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Inventory_Shipment.Service.Mapping;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

public sealed class PartyService : IPartyService
{
    private const string NotFoundMessage = "Party not found.";
    private const string NoTypeMessage = "Select at least one party type (Supplier, Client, Salesman or Employee).";

    private readonly IPartyRepository _parties;
    private readonly ILogger<PartyService> _logger;

    public PartyService(IPartyRepository parties, ILogger<PartyService> logger)
    {
        _parties = parties;
        _logger = logger;
    }

    public async Task<Result<PagedResult<PartyDto>>> SearchAsync(
        PartyQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _parties.SearchAsync(query, cancellationToken);

        return Result<PagedResult<PartyDto>>.Success(new PagedResult<PartyDto>
        {
            Items = items.Select(p => p.ToDto()).ToList(),
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount
        });
    }

    public async Task<Result<PartyDto>> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        var party = await _parties.GetAsync(id, cancellationToken);

        return party is null
            ? Result<PartyDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<PartyDto>.Success(party.ToDto());
    }

    public async Task<Result<PartyDto>> CreateAsync(
        SavePartyRequest request, int userId, CancellationToken cancellationToken = default)
    {
        if (!HasAnyType(request))
        {
            return Result<PartyDto>.Failure(ErrorType.Validation, NoTypeMessage, "VALIDATION");
        }

        var party = ToEntity(request);

        int id;
        try
        {
            id = await _parties.CreateAsync(party, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PartyDto>(ex);
        }

        _logger.LogInformation("Party {PartyId} ({PartyCode}) created by user {UserId}",
            id, party.PartyCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<PartyDto>> UpdateAsync(
        int id, SavePartyRequest request, int userId, CancellationToken cancellationToken = default)
    {
        if (!HasAnyType(request))
        {
            return Result<PartyDto>.Failure(ErrorType.Validation, NoTypeMessage, "VALIDATION");
        }

        byte[]? rowVersion;
        try
        {
            rowVersion = string.IsNullOrWhiteSpace(request.RowVersion)
                ? null
                : Convert.FromBase64String(request.RowVersion);
        }
        catch (FormatException)
        {
            return Result<PartyDto>.Failure(
                ErrorType.Validation, "The supplied RowVersion is not a valid Base64 value.", "VALIDATION");
        }

        var party = ToEntity(request);
        party.Id = id;

        try
        {
            await _parties.UpdateAsync(party, rowVersion, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PartyDto>(ex);
        }

        _logger.LogInformation("Party {PartyId} ({PartyCode}) updated by user {UserId}",
            id, party.PartyCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<PartyDto>> SetActiveAsync(
        int id, bool isActive, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            await _parties.SetActiveAsync(id, isActive, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<PartyDto>(ex);
        }

        _logger.LogInformation("Party {PartyId} {Status} by user {UserId}",
            id, isActive ? "activated" : "deactivated", userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default)
    {
        try
        {
            await _parties.DeleteAsync(id, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Party {PartyId} deleted", id);
        return Result.Success();
    }

    public async Task<Result<IReadOnlyList<PartyLookupDto>>> LookupAsync(
        PartyType? partyType, string? search, bool activeOnly, int? includeId, int top,
        CancellationToken cancellationToken = default)
    {
        var parties = await _parties.LookupAsync(partyType, search, activeOnly, includeId, top, cancellationToken);
        return Result<IReadOnlyList<PartyLookupDto>>.Success(parties.Select(p => p.ToDto()).ToList());
    }

    public async Task<Result<NextCodeDto>> NextCodeAsync(
        PartyType partyType, CancellationToken cancellationToken = default)
    {
        string suggestedCode;
        try
        {
            suggestedCode = await _parties.NextCodeAsync(partyType, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<NextCodeDto>(ex);
        }

        return Result<NextCodeDto>.Success(new NextCodeDto { SuggestedCode = suggestedCode });
    }

    // ----- helpers -----

    /// <summary>
    /// The database enforces "at least one type" with a CHECK constraint, but a constraint violation
    /// is not a business rule THROW: checking it here turns it into a plain 400 the form can show.
    /// </summary>
    private static bool HasAnyType(SavePartyRequest request)
        => request.IsSupplier || request.IsClient || request.IsSalesman || request.IsEmployee;

    private static Party ToEntity(SavePartyRequest request) => new()
    {
        PartyCode = request.PartyCode.Trim(),
        PartyName = request.PartyName.Trim(),
        IsSupplier = request.IsSupplier,
        IsClient = request.IsClient,
        IsSalesman = request.IsSalesman,
        IsEmployee = request.IsEmployee,
        BranchId = request.BranchId,
        ContactPerson = Clean(request.ContactPerson),
        Phone = Clean(request.Phone),
        Mobile = Clean(request.Mobile),
        Email = Clean(request.Email),
        Address = Clean(request.Address),
        // ISO 3166-1 alpha-2 codes are upper-case; the procedure normalizes too, but the entity
        // is what the log line and any later comparison see.
        Country = Clean(request.Country)?.ToUpperInvariant(),
        TaxRegistrationNo = Clean(request.TaxRegistrationNo),
        Notes = Clean(request.Notes),
        UserId = request.UserId,
        DefaultPriceListId = request.DefaultPriceListId,
        DefaultCurrencyId = request.DefaultCurrencyId,
        IsActive = request.IsActive
    };

    private static string? Clean(string? value)
        => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private async Task<Result<PartyDto>> ReadBackAsync(int id, CancellationToken cancellationToken)
    {
        var saved = await _parties.GetAsync(id, cancellationToken);

        return saved is null
            ? Result<PartyDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<PartyDto>.Success(saved.ToDto());
    }

    /// <summary>How one business rule raised by the procedures is reported to the client.</summary>
    private sealed record RuleFailure(ErrorType Type, string Message, string Code);

    private static Result<T> Failure<T>(BusinessRuleException exception)
    {
        var failure = Describe(exception);
        return Result<T>.Failure(failure.Type, failure.Message, failure.Code);
    }

    private static RuleFailure Describe(BusinessRuleException exception) => exception.Number switch
    {
        SqlErrors.PartyDuplicateCode => new RuleFailure(
            ErrorType.Conflict, "A party with this Party Code already exists.", "DUPLICATE_CODE"),

        SqlErrors.PartyUserAlreadyLinked => new RuleFailure(
            ErrorType.Conflict, "This user is already linked to another party.", "USER_ALREADY_LINKED"),

        SqlErrors.PartyReferenced => new RuleFailure(
            ErrorType.Conflict,
            "This party cannot be deleted because it is referenced by existing transactions. You may deactivate the party instead.",
            "REFERENCED"),

        SqlErrors.PartyConcurrency => new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY"),

        // The message names the type that is still in use ("The Supplier type cannot be removed: ...").
        SqlErrors.PartyTypeInUse => new RuleFailure(ErrorType.Conflict, exception.Message, "TYPE_IN_USE"),

        SqlErrors.PartyNotFound => new RuleFailure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND"),

        // Branch, price list, currency or linked user missing or inactive - the message says which.
        SqlErrors.PartyMasterInactive => new RuleFailure(ErrorType.Validation, exception.Message, "MASTER_INACTIVE"),

        _ => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION")
    };
}
