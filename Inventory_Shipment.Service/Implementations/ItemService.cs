using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Model.Enums;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Inventory_Shipment.Service.Mapping;
using Inventory_Shipment.Service.Security;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

public sealed class ItemService : IItemService
{
    private const string NotFoundMessage = "Item not found.";
    private const string FileNotFoundMessage = "File not found.";

    /// <summary>
    /// Largest item picture. THE PICTURE ONLY: the item's documents follow the rules of every attachment
    /// (<see cref="AttachmentRules"/>, 20 MB), checked by the controller as for every other page.
    /// </summary>
    private const int MaxImageBytes = 5 * 1024 * 1024;

    /// <summary>What the item image may be - the picture is rendered straight into an img tag.</summary>
    private static readonly HashSet<string> ImageContentTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "image/jpeg", "image/png", "image/webp"
    };

    private readonly IItemRepository _items;
    private readonly ILogger<ItemService> _logger;

    public ItemService(IItemRepository items, ILogger<ItemService> logger)
    {
        _items = items;
        _logger = logger;
    }

    public async Task<Result<PagedResult<ItemListDto>>> SearchAsync(
        ItemQuery query, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await _items.SearchAsync(query, cancellationToken);
        var seesCosts = ItemCosts.Sees(permissions);

        return Result<PagedResult<ItemListDto>>.Success(new PagedResult<ItemListDto>
        {
            // (94) The list and the item search behind every scan box: the costs and the value null without View item costs.
            Items = items.Select(i => seesCosts ? i.ToListDto() : ItemCosts.Strip(i.ToListDto())).ToList(),
            Page = query.Page,
            PageSize = query.PageSize,
            TotalCount = totalCount
        });
    }

    public async Task<Result<ItemDetailsDto>> GetAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
        => await ReadBackAsync(id, permissions, cancellationToken);

    public async Task<Result<ItemContainersDto>> GetContainersAsync(int id, CancellationToken cancellationToken = default)
    {
        var loaded = await _items.GetAsync(id, cancellationToken);
        if (loaded is null)
        {
            return Result<ItemContainersDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND");
        }

        // 8 = Cancelled: what such a container was loaded with never left.
        var containers = await _items.GetContainersAsync(id, cancellationToken);
        var live = containers.Where(c => c.StatusCode != 8).ToList();
        return Result<ItemContainersDto>.Success(new ItemContainersDto
        {
            ItemId = id,
            ItemCode = loaded.Value.Item.ItemCode,
            ItemName = loaded.Value.Item.ItemName,
            ContainersOnTheWay = containers.Count(c => c.OnTheWayBase > 0),
            OnTheWayBase = containers.Sum(c => c.OnTheWayBase),
            LoadedBase = live.Sum(c => c.LoadedBase),
            ReceivedBase = live.Sum(c => c.ReceivedBase),
            Containers = containers,
        });
    }

    public async Task<Result<ItemPurchaseOrdersDto>> GetPurchaseOrdersAsync(int id, CancellationToken cancellationToken = default)
    {
        var loaded = await _items.GetAsync(id, cancellationToken);
        if (loaded is null)
        {
            return Result<ItemPurchaseOrdersDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND");
        }

        var orders = await _items.GetPurchaseOrdersAsync(id, cancellationToken);
        var live = orders.Where(o => o.StatusCode != PurchaseDocumentStatus.CancelledCode).ToList();
        return Result<ItemPurchaseOrdersDto>.Success(new ItemPurchaseOrdersDto
        {
            ItemId = id,
            ItemCode = loaded.Value.Item.ItemCode,
            ItemName = loaded.Value.Item.ItemName,
            OpenOrders = orders.Count(o => o.OutstandingBase > 0),
            OutstandingBase = orders.Sum(o => o.OutstandingBase),
            OrderedBase = live.Sum(o => o.OrderedBase),
            ReceivedBase = live.Sum(o => o.ReceivedBase),
            InvoicedBase = live.Sum(o => o.InvoicedBase),
            ShortBase = live.Sum(o => o.ShortBase),
            Orders = orders,
        });
    }

    public async Task<Result<ItemStockStatementDto>> GetStockStatementAsync(
        int id, DateOnly? from, DateOnly? to, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if (from is not null && to is not null && to < from)
        {
            return Result<ItemStockStatementDto>.Failure(ErrorType.Validation, "The end date cannot be before the start date.", "VALIDATION");
        }

        var loaded = await _items.GetAsync(id, cancellationToken);
        if (loaded is null)
        {
            return Result<ItemStockStatementDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND");
        }

        var (opening, movements) = await _items.GetStockStatementAsync(id, from, to, cancellationToken);
        var totalIn = movements.Sum(m => m.QuantityIn);
        var totalOut = movements.Sum(m => m.QuantityOut);
        var statement = new ItemStockStatementDto
        {
            ItemId = id,
            ItemCode = loaded.Value.Item.ItemCode,
            ItemName = loaded.Value.Item.ItemName,
            OpeningBase = opening,
            TotalIn = totalIn,
            TotalOut = totalOut,
            ClosingBase = opening + totalIn - totalOut,
            Movements = movements,
        };

        // (94) Each movement's unit cost (the transfer rows too) null without View item costs.
        return Result<ItemStockStatementDto>.Success(ItemCosts.Sees(permissions) ? statement : ItemCosts.Strip(statement));
    }

    public async Task<Result<ItemStockBalanceDto>> GetStockBalanceAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        var loaded = await _items.GetAsync(id, cancellationToken);
        if (loaded is null)
        {
            return Result<ItemStockBalanceDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND");
        }

        var rows = await _items.GetStockBalanceAsync(id, cancellationToken);
        var balance = new ItemStockBalanceDto
        {
            ItemId = id,
            ItemCode = loaded.Value.Item.ItemCode,
            ItemName = loaded.Value.Item.ItemName,
            Warehouses = rows,
            TotalOnHandBase = rows.Sum(r => r.OnHandBase),
            TotalInventoryValue = rows.Sum(r => r.InventoryValue),
        };

        // (94) Stripped AFTER the total is computed: the averages, the values and the total null without View item costs.
        return Result<ItemStockBalanceDto>.Success(ItemCosts.Sees(permissions) ? balance : ItemCosts.Strip(balance));
    }

    public async Task<Result<ItemDetailsDto>> CreateAsync(
        SaveItemRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if ((ValidateQuantities(request) ?? ValidateLink(request) ?? ValidateTracking(request, isNew: true)) is { } validationError)
        {
            return Result<ItemDetailsDto>.Failure(ErrorType.Validation, validationError, "VALIDATION");
        }

        var item = ToEntity(request);

        int id;
        try
        {
            id = await _items.CreateAsync(item, userId, cancellationToken);
            // The purchasing fields live in their own procedure (script 19); same call, same caller.
            await _items.SetPurchasingAsync(
                id, item.DefaultSupplierId, item.LeadTimeDays, item.PcPerContainer, item.WeightKg, item.VolumeCbm, userId, cancellationToken);
            // So do the note and the link (script 87).
            await _items.SetNotesAsync(id, item.Note, item.Link, userId, cancellationToken);
            await _items.SetLeadTimeAsync(id, item.LeadTimeMonths, userId, cancellationToken);   // (98)
            // And the tracking (script 93): always on a new item, None / no / any length when the request has none.
            var tracking = TrackingOf(request);
            await _items.SetTrackingAsync(id, tracking.Mode, tracking.RequiresExpiry, tracking.SerialLength, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ItemDetailsDto>(ex);
        }

        _logger.LogInformation("Item {ItemId} ({ItemCode}) created by user {UserId}", id, item.ItemCode, userId);

        return await ReadBackAsync(id, permissions, cancellationToken);
    }

    public async Task<Result<ItemDetailsDto>> UpdateAsync(
        int id, SaveItemRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default)
    {
        if ((ValidateQuantities(request) ?? ValidateLink(request) ?? ValidateTracking(request, isNew: false)) is { } validationError)
        {
            return Result<ItemDetailsDto>.Failure(ErrorType.Validation, validationError, "VALIDATION");
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
            await _items.SetPurchasingAsync(
                id, item.DefaultSupplierId, item.LeadTimeDays, item.PcPerContainer, item.WeightKg, item.VolumeCbm, userId, cancellationToken);
            await _items.SetNotesAsync(id, item.Note, item.Link, userId, cancellationToken);
            await _items.SetLeadTimeAsync(id, item.LeadTimeMonths, userId, cancellationToken);   // (98)
            // (93) Only when the request carries trackingMode: a client that does not know the fields changes nothing.
            if (request.TrackingMode is not null)
            {
                var tracking = TrackingOf(request);
                await _items.SetTrackingAsync(id, tracking.Mode, tracking.RequiresExpiry, tracking.SerialLength, userId, cancellationToken);
            }
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ItemDetailsDto>(ex);
        }

        _logger.LogInformation("Item {ItemId} ({ItemCode}) updated by user {UserId}", id, item.ItemCode, userId);

        return await ReadBackAsync(id, permissions, cancellationToken);
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

    public async Task<Result> DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
    {
        try
        {
            await _items.DeleteAsync(id, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            var failure = Describe(ex);
            return Result.Failure(failure.Type, failure.Message, failure.Code);
        }

        _logger.LogInformation("Item {ItemId} deleted by user {UserId}", id, userId);
        return Result.Success();
    }

    public async Task<Result<IReadOnlyList<ItemLookupDto>>> LookupAsync(
        bool activeOnly, int? includeId, bool salesOnly = false, bool bivacOnly = false,
        string? search = null, int? top = null, CancellationToken cancellationToken = default)
    {
        var items = await _items.LookupAsync(activeOnly, includeId, salesOnly, bivacOnly, search, top, cancellationToken);
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

    public async Task<Result<ItemFileDto>> AddImageAsync(
        int itemId, ItemFileUpload upload, int userId, CancellationToken cancellationToken = default)
    {
        if (upload.SizeBytes <= 0)
        {
            return Result<ItemFileDto>.Failure(ErrorType.Validation, "The file is empty.", "VALIDATION");
        }

        if (upload.SizeBytes > MaxImageBytes)
        {
            return Result<ItemFileDto>.Failure(
                ErrorType.Validation, "The file is larger than the 5 MB limit.", "VALIDATION");
        }

        var contentType = upload.ContentType?.Trim() ?? string.Empty;
        if (!ImageContentTypes.Contains(contentType))
        {
            return Result<ItemFileDto>.Failure(
                ErrorType.Validation, "The item image must be a JPEG, PNG or WebP file.", "VALIDATION");
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

        if (content.Length > MaxImageBytes)
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
            IsItemImage = true,
            Content = content
        };

        try
        {
            // No fields: the picture has no type, date or note.
            await _items.AddFileAsync(file, fields: null, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<ItemFileDto>(ex);
        }

        _logger.LogInformation("Picture {FileId} ({FileName}, {SizeBytes} bytes) added to item {ItemId} by user {UserId}",
            file.Id, file.FileName, file.SizeBytes, itemId, userId);

        return Result<ItemFileDto>.Success(file.ToDto());
    }

    public async Task<Result<int>> AddDocumentFileAsync(
        int itemId, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        CancellationToken cancellationToken = default)
    {
        var name = Path.GetFileName(fileName.Trim());
        if (name.Length == 0)
        {
            return Result<int>.Failure(ErrorType.Validation, "The file name is required.", "VALIDATION");
        }

        var file = new ItemFile
        {
            ItemId = itemId,
            FileName = name,
            ContentType = string.IsNullOrWhiteSpace(contentType) ? "application/octet-stream" : contentType.Trim(),
            SizeBytes = content.Length,
            IsItemImage = false,
            Content = content
        };

        try
        {
            await _items.AddFileAsync(file, fields, userId, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<int>(ex);
        }

        _logger.LogInformation(
            "Document {FileId} ({FileName}, {SizeBytes} bytes, type {AttachmentTypeId}) added to item {ItemId} by user {UserId}",
            file.Id, file.FileName, file.SizeBytes, fields.AttachmentTypeId, itemId, userId);

        return Result<int>.Success(file.Id);
    }

    public async Task<Result<IReadOnlyList<DocumentFileDto>>> ListFilesAsync(
        int itemId, int? attachmentTypeId, CancellationToken cancellationToken = default)
    {
        if (await _items.GetAsync(itemId, cancellationToken) is null)
        {
            return Result<IReadOnlyList<DocumentFileDto>>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND");
        }

        return Result<IReadOnlyList<DocumentFileDto>>.Success(
            await _items.ListFilesAsync(itemId, attachmentTypeId, cancellationToken: cancellationToken));
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

    public async Task<Result<DocumentFileDto>> UpdateFileAsync(
        int itemId, int fileId, DocumentFileEdit edit, int userId, CancellationToken cancellationToken = default)
    {
        // CHECKED AGAINST THE ITEM IN THE ROUTE through the documents' list, which never holds the picture: a
        // file of another item, or the picture, is not a document of this item.
        if ((await _items.ListFilesAsync(itemId, fileId: fileId, cancellationToken: cancellationToken)).Count == 0)
        {
            return Result<DocumentFileDto>.Failure(ErrorType.NotFound, FileNotFoundMessage, "NOT_FOUND");
        }

        DocumentFileDto? row;
        try
        {
            row = await _items.UpdateFileAsync(
                fileId, edit.FileName, edit.ContentType, edit.Content, edit.Fields, cancellationToken);
        }
        catch (BusinessRuleException ex)
        {
            return Failure<DocumentFileDto>(ex);
        }

        _logger.LogInformation("Document {FileId} of item {ItemId} updated{Replaced} by user {UserId}",
            fileId, itemId, edit.Content is null ? string.Empty : " with new content", userId);

        return row is null
            ? Result<DocumentFileDto>.Failure(ErrorType.NotFound, FileNotFoundMessage, "NOT_FOUND")
            : Result<DocumentFileDto>.Success(row);
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
        DefaultSupplierId = request.DefaultSupplierId,
        // (98) The months win; an older client's days become months (/ 30, to the half month), as script 98 converted them.
        LeadTimeMonths = LeadTimeMonthsOf(request),
        LeadTimeDays = LeadTimeMonthsOf(request) is { } months ? (int)Math.Round(months * 30, MidpointRounding.AwayFromZero) : null,
        PcPerContainer = request.PcPerContainer,
        WeightKg = request.WeightKg,
        VolumeCbm = request.VolumeCbm,
        Description = Normalize(request.Description),
        Note = Normalize(request.Note),
        Link = Normalize(request.Link),
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
        IsBaseUnit = request.IsBaseUnit,
        LengthCm = request.LengthCm,
        WidthCm = request.WidthCm,
        HeightCm = request.HeightCm,
        WeightKg = request.WeightKg
    };

    private static string? Normalize(string? value)
        => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    /// <summary>The procedures reject this too; catching it here keeps the message next to the field.</summary>
    private static string? ValidateQuantities(SaveItemRequest request)
        => request.MaxQuantity is { } max && max < request.MinQuantity
            ? "Minimum Quantity cannot exceed Maximum Quantity."
            : null;

    /* THE PAGE OPENS THE LINK IN A NEW TAB, so only an absolute http(s) address with a host is accepted: no
       javascript:, no file path, no spaces. usp_Item_SetNotes refuses the same, as the last guard. */
    private static string? ValidateLink(SaveItemRequest request)
    {
        var link = Normalize(request.Link);
        if (link is null)
        {
            return null;
        }

        var valid = !link.Any(char.IsWhiteSpace)
            && Uri.TryCreate(link, UriKind.Absolute, out var uri)
            && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps)
            && !string.IsNullOrEmpty(uri.Host);

        return valid ? null : "Link must be a web address starting with http:// or https://, for example https://www.tvsmotor.com.";
    }

    /* (93) TRACKING ON TRANSFERS. Checked here so the sentence sits next to the field (the page's red Alert, like the link);
       usp_Item_SetTracking refuses the same, in its words, as the last guard. An update without trackingMode leaves the
       three fields alone, whatever else it carries. */
    private static string? ValidateTracking(SaveItemRequest request, bool isNew)
    {
        if (request.TrackingMode is null && !isNew)
        {
            return null;
        }

        var mode = TrackingMode.None;
        if (request.TrackingMode is not null && !Tracking.TryParseMode(request.TrackingMode, out mode))
        {
            return "Tracking must be None, Batch or Serial.";
        }

        return request.SerialLength is not null && mode != TrackingMode.Serial
            ? "Serial no. length applies to serial-numbered items only."
            : null;
    }

    /// <summary>The request's tracking, after <see cref="ValidateTracking"/>: absent = None, no expiry, any length.</summary>
    private static (TrackingMode Mode, bool RequiresExpiry, int? SerialLength) TrackingOf(SaveItemRequest request)
    {
        var mode = Tracking.TryParseMode(request.TrackingMode, out var parsed) ? parsed : TrackingMode.None;
        return (mode, request.RequiresExpiry ?? false, mode == TrackingMode.Serial ? request.SerialLength : null);
    }

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

    /// <summary>The item card as this reader receives it: (94) its costs and value null without View item costs.</summary>
    private async Task<Result<ItemDetailsDto>> ReadBackAsync(
        int id, IReadOnlySet<string> permissions, CancellationToken cancellationToken)
    {
        var loaded = await _items.GetAsync(id, cancellationToken);
        if (loaded is null)
        {
            return Result<ItemDetailsDto>.Failure(ErrorType.NotFound, NotFoundMessage, "NOT_FOUND");
        }

        var item = loaded.Value.Item.ToDetailsDto(loaded.Value.Units, loaded.Value.Files);
        return Result<ItemDetailsDto>.Success(ItemCosts.Sees(permissions) ? item : ItemCosts.Strip(item));
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

        // Script 67: "Choose the attachment type." / "The attachment type ... is not used for items." - as it comes.
        SqlErrors.ItemAttachmentType => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION"),

        SqlErrors.ItemNotFound => new RuleFailure(ErrorType.NotFound, exception.Message, "NOT_FOUND"),

        _ => new RuleFailure(ErrorType.Validation, exception.Message, "VALIDATION")
    };

    /// <summary>(98) The request's lead time in months: typed, else its days as months (/ 30, to the half month), else none.</summary>
    private static decimal? LeadTimeMonthsOf(SaveItemRequest request)
        => request.LeadTimeMonths is { } months
            ? Math.Round(months, 1, MidpointRounding.AwayFromZero)
            : request.LeadTimeDays is { } days
                ? Math.Min(60m, Math.Round(days / 30m * 2, MidpointRounding.AwayFromZero) / 2)
                : null;
}
