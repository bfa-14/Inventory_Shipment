using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Inventory_Shipment.Service.Mapping;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

public sealed class ItemService : IItemService
{
    private const string NotFoundMessage = "Item not found.";
    private const string FileNotFoundMessage = "File not found.";

    /// <summary>Largest upload the database column and the UI both promise to handle.</summary>
    private const int MaxFileBytes = 5 * 1024 * 1024;

    /// <summary>What the item image may be - the picture is rendered straight into an img tag.</summary>
    private static readonly HashSet<string> ImageContentTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "image/jpeg", "image/png", "image/webp"
    };

    /// <summary>What an attachment may be: the image types plus the usual documents.</summary>
    private static readonly HashSet<string> AttachmentContentTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "image/jpeg", "image/png", "image/webp",
        "application/pdf",
        "application/msword",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.ms-excel",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "text/plain"
    };

    private readonly IItemRepository _items;
    private readonly ILogger<ItemService> _logger;

    public ItemService(IItemRepository items, ILogger<ItemService> logger)
    {
        _items = items;
        _logger = logger;
    }

    public async Task<Result<PagedResult<ItemListDto>>> SearchAsync(
        ItemQuery query, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _items.SearchAsync(query, cancellationToken);

        return Result<PagedResult<ItemListDto>>.Success(new PagedResult<ItemListDto>
        {
            Items = items.Select(i => i.ToListDto()).ToList(),
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount
        });
    }

    public async Task<Result<ItemDetailsDto>> GetAsync(int id, CancellationToken cancellationToken = default)
        => await ReadBackAsync(id, cancellationToken);

    public async Task<Result<ItemDetailsDto>> CreateAsync(
        SaveItemRequest request, int userId, CancellationToken cancellationToken = default)
    {
        if (ValidateQuantities(request) is { } quantityError)
        {
            return Result<ItemDetailsDto>.Failure(ErrorType.Validation, quantityError, "VALIDATION");
        }

        var item = ToEntity(request);

        int id;
        try
        {
            id = await _items.CreateAsync(item, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ItemDetailsDto>(ex);
        }

        _logger.LogInformation("Item {ItemId} ({ItemCode}) created by user {UserId}", id, item.ItemCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result<ItemDetailsDto>> UpdateAsync(
        int id, SaveItemRequest request, int userId, CancellationToken cancellationToken = default)
    {
        if (ValidateQuantities(request) is { } quantityError)
        {
            return Result<ItemDetailsDto>.Failure(ErrorType.Validation, quantityError, "VALIDATION");
        }

        if (!TryReadRowVersion(request.RowVersion, out var rowVersion))
        {
            return Result<ItemDetailsDto>.Failure(
                ErrorType.Validation, "The supplied RowVersion is not a valid Base64 value.", "VALIDATION");
        }

        var item = ToEntity(request);
        item.Id = id;

        try
        {
            await _items.UpdateAsync(item, rowVersion, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ItemDetailsDto>(ex);
        }

        _logger.LogInformation("Item {ItemId} ({ItemCode}) updated by user {UserId}", id, item.ItemCode, userId);

        return await ReadBackAsync(id, cancellationToken);
    }

    public async Task<Result> SetActiveAsync(
        int id, bool isActive, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            await _items.SetActiveAsync(id, isActive, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Item {ItemId} {Status} by user {UserId}",
            id, isActive ? "activated" : "deactivated", userId);

        return Result.Success();
    }

    public async Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default)
    {
        try
        {
            await _items.DeleteAsync(id, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Item {ItemId} deleted", id);
        return Result.Success();
    }

    public async Task<Result<IReadOnlyList<ItemLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default)
    {
        var items = await _items.LookupAsync(activeOnly, includeId, cancellationToken);
        return Result<IReadOnlyList<ItemLookupDto>>.Success(items.Select(i => i.ToDto()).ToList());
    }

    // ----- units -----

    public async Task<Result<IReadOnlyList<ItemUnitDto>>> AddUnitAsync(
        int itemId, SaveItemUnitRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var unit = ToEntity(request);
        unit.ItemId = itemId;

        try
        {
            await _items.CreateUnitAsync(unit, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<ItemUnitDto>>(ex);
        }

        _logger.LogInformation("Unit {UnitId} ({SkuCode}) added to item {ItemId} by user {UserId}",
            unit.Id, unit.SkuCode, itemId, userId);

        return await ReadUnitsAsync(itemId, cancellationToken);
    }

    public async Task<Result<IReadOnlyList<ItemUnitDto>>> UpdateUnitAsync(
        int itemId, int unitId, SaveItemUnitRequest request, int userId, CancellationToken cancellationToken = default)
    {
        if (!TryReadRowVersion(request.RowVersion, out var rowVersion))
        {
            return Result<IReadOnlyList<ItemUnitDto>>.Failure(
                ErrorType.Validation, "The supplied RowVersion is not a valid Base64 value.", "VALIDATION");
        }

        if (await FindUnitAsync(itemId, unitId, cancellationToken) is null)
        {
            return Result<IReadOnlyList<ItemUnitDto>>.Failure(
                ErrorType.NotFound, "Item unit not found.", "NOT_FOUND");
        }

        var unit = ToEntity(request);
        unit.Id = unitId;
        unit.ItemId = itemId;

        try
        {
            await _items.UpdateUnitAsync(unit, rowVersion, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<IReadOnlyList<ItemUnitDto>>(ex);
        }

        _logger.LogInformation("Unit {UnitId} of item {ItemId} updated by user {UserId}", unitId, itemId, userId);

        return await ReadUnitsAsync(itemId, cancellationToken);
    }

    public async Task<Result> DeleteUnitAsync(int itemId, int unitId, CancellationToken cancellationToken = default)
    {
        if (await FindUnitAsync(itemId, unitId, cancellationToken) is null)
        {
            return Result.Failure(ErrorType.NotFound, "Item unit not found.", "NOT_FOUND");
        }

        try
        {
            await _items.DeleteUnitAsync(unitId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Unit {UnitId} of item {ItemId} deleted", unitId, itemId);
        return Result.Success();
    }

    // ----- files -----

    public async Task<Result<ItemFileDto>> AddFileAsync(
        int itemId, ItemFileUpload upload, bool isItemImage, int userId, CancellationToken cancellationToken = default)
    {
        if (upload.SizeBytes <= 0)
        {
            return Result<ItemFileDto>.Failure(ErrorType.Validation, "The file is empty.", "VALIDATION");
        }

        if (upload.SizeBytes > MaxFileBytes)
        {
            return Result<ItemFileDto>.Failure(
                ErrorType.Validation, "The file is larger than the 5 MB limit.", "VALIDATION");
        }

        var contentType = upload.ContentType?.Trim() ?? string.Empty;
        var allowed = isItemImage ? ImageContentTypes : AttachmentContentTypes;

        if (!allowed.Contains(contentType))
        {
            return Result<ItemFileDto>.Failure(
                ErrorType.Validation,
                isItemImage
                    ? "The item image must be a JPEG, PNG or WebP file."
                    : "Allowed attachments are images (JPEG, PNG, WebP), PDF, Word, Excel and plain text files.",
                "VALIDATION");
        }

        // Only the name matters - a browser may send a full path on some platforms.
        var fileName = Path.GetFileName(upload.FileName?.Trim() ?? string.Empty);
        if (string.IsNullOrEmpty(fileName))
        {
            return Result<ItemFileDto>.Failure(ErrorType.Validation, "The file name is required.", "VALIDATION");
        }

        using var buffer = new MemoryStream();
        await upload.Content.CopyToAsync(buffer, cancellationToken);
        var content = buffer.ToArray();

        // The reported length is a hint; the bytes that actually arrived are what gets stored.
        if (content.Length == 0)
        {
            return Result<ItemFileDto>.Failure(ErrorType.Validation, "The file is empty.", "VALIDATION");
        }

        if (content.Length > MaxFileBytes)
        {
            return Result<ItemFileDto>.Failure(
                ErrorType.Validation, "The file is larger than the 5 MB limit.", "VALIDATION");
        }

        var file = new ItemFile
        {
            ItemId = itemId,
            FileName = fileName,
            ContentType = contentType,
            SizeBytes = content.Length,
            IsItemImage = isItemImage,
            Content = content
        };

        try
        {
            await _items.AddFileAsync(file, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ItemFileDto>(ex);
        }

        _logger.LogInformation("File {FileId} ({FileName}, {SizeBytes} bytes) added to item {ItemId} by user {UserId}",
            file.Id, file.FileName, file.SizeBytes, itemId, userId);

        return Result<ItemFileDto>.Success(file.ToDto());
    }

    public async Task<Result<ItemFile>> GetFileAsync(
        int itemId, int fileId, CancellationToken cancellationToken = default)
    {
        var file = await _items.GetFileAsync(fileId, cancellationToken);

        // A file id from another item must not become a way to read that item's documents.
        return file is null || file.ItemId != itemId
            ? Result<ItemFile>.Failure(ErrorType.NotFound, FileNotFoundMessage, "NOT_FOUND")
            : Result<ItemFile>.Success(file);
    }

    public async Task<Result> DeleteFileAsync(int itemId, int fileId, CancellationToken cancellationToken = default)
    {
        var file = await _items.GetFileAsync(fileId, cancellationToken);

        if (file is null || file.ItemId != itemId)
        {
            return Result.Failure(ErrorType.NotFound, FileNotFoundMessage, "NOT_FOUND");
        }

        try
        {
            await _items.DeleteFileAsync(fileId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("File {FileId} of item {ItemId} deleted", fileId, itemId);
        return Result.Success();
    }

    // ----- helpers -----

    private static Item ToEntity(SaveItemRequest request) => new()
    {
        ItemCode = request.ItemCode.Trim(),
        ItemName = request.ItemName.Trim(),
        BrandId = request.BrandId,
        Model = Normalize(request.Model),
        ItemFamilyId = request.ItemFamilyId,
        CountryOfOrigin = request.CountryOfOrigin.Trim().ToUpperInvariant(),
        DefaultWarehouseId = request.DefaultWarehouseId,
        Description = Normalize(request.Description),
        WarrantyMonths = request.WarrantyMonths,
        MinQuantity = request.MinQuantity,
        MaxQuantity = request.MaxQuantity,
        IsBivac = request.IsBivac,
        IsActive = request.IsActive
    };

    private static ItemUnit ToEntity(SaveItemUnitRequest request) => new()
    {
        UnitTypeId = request.UnitTypeId,
        // The base unit is the yardstick every other formula is expressed in, so its own formula is 1.
        PackingFormula = request.IsBaseUnit ? 1 : request.PackingFormula,
        SkuCode = request.SkuCode.Trim(),
        Barcode = Normalize(request.Barcode),
        IsSalesUnit = request.IsSalesUnit,
        IsPurchaseUnit = request.IsPurchaseUnit,
        IsBaseUnit = request.IsBaseUnit
    };

    private static string? Normalize(string? value)
        => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    /// <summary>The procedures reject this too; catching it here keeps the message next to the field.</summary>
    private static string? ValidateQuantities(SaveItemRequest request)
        => request.MaxQuantity is { } max && max < request.MinQuantity
            ? "Minimum Quantity cannot exceed Maximum Quantity."
            : null;

    private static bool TryReadRowVersion(string? value, out byte[]? rowVersion)
    {
        rowVersion = null;

        if (string.IsNullOrWhiteSpace(value))
        {
            return true;
        }

        try
        {
            rowVersion = Convert.FromBase64String(value);
            return true;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private async Task<ItemUnit?> FindUnitAsync(int itemId, int unitId, CancellationToken cancellationToken)
    {
        var loaded = await _items.GetAsync(itemId, cancellationToken);
        return loaded?.Units.FirstOrDefault(u => u.Id == unitId);
    }

    private async Task<Result<ItemDetailsDto>> ReadBackAsync(int id, CancellationToken cancellationToken)
    {
        var loaded = await _items.GetAsync(id, cancellationToken);

        return loaded is null
            ? Result<ItemDetailsDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<ItemDetailsDto>.Success(loaded.Value.Item.ToDetailsDto(loaded.Value.Units, loaded.Value.Files));
    }

    private async Task<Result<IReadOnlyList<ItemUnitDto>>> ReadUnitsAsync(int id, CancellationToken cancellationToken)
    {
        var loaded = await _items.GetAsync(id, cancellationToken);

        return loaded is null
            ? Result<IReadOnlyList<ItemUnitDto>>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND")
            : Result<IReadOnlyList<ItemUnitDto>>.Success(loaded.Value.Units.Select(u => u.ToDto()).ToList());
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
        SqlErrors.ItemDuplicateCode => new RuleFailure(
            ErrorType.Conflict, "An item with this Item Code already exists.", "DUPLICATE_CODE"),

        SqlErrors.ItemDuplicateBarcode => new RuleFailure(
            ErrorType.Conflict, "This Barcode is already used by another unit in the system.", "DUPLICATE_BARCODE"),

        SqlErrors.ItemDuplicateSku => new RuleFailure(
            ErrorType.Conflict, "This SKU Code is already used by another unit of this item.", "DUPLICATE_SKU"),

        SqlErrors.ItemReferenced => new RuleFailure(ErrorType.Conflict, exception.Message, "REFERENCED"),

        SqlErrors.ItemConcurrency => new RuleFailure(ErrorType.Conflict, exception.Message, "CONCURRENCY"),

        SqlErrors.ItemBaseUnitRule => new RuleFailure(ErrorType.Conflict, exception.Message, "BASE_UNIT_RULE"),

        SqlErrors.ItemMasterInactive => new RuleFailure(ErrorType.Validation, exception.Message, "MASTER_INACTIVE"),

        SqlErrors.ItemNotFound => new RuleFailure(ErrorType.NotFound, exception.Message, "NOT_FOUND"),

        _ => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION")
    };
}
