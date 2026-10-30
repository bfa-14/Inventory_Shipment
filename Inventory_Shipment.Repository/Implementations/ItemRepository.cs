using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Inventory;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class ItemRepository : IItemRepository
{
    /// <summary>Columns the search procedure accepts; anything else falls back to ItemCode.</summary>
    private static readonly string[] SortColumns =
        ["ItemCode", "ItemName", "BrandName", "FamilyName", "WarehouseName", "IsActive", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public ItemRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>Flat shape the search procedure returns: the item columns plus the windowed total.</summary>
    private sealed class ItemRow
    {
        public int Id { get; init; }
        public string ItemCode { get; init; } = string.Empty;
        public string ItemName { get; init; } = string.Empty;
        public int BrandId { get; init; }
        public string BrandName { get; init; } = string.Empty;
        public string? Model { get; init; }
        public int ItemFamilyId { get; init; }
        public string FamilyCode { get; init; } = string.Empty;
        public string FamilyName { get; init; } = string.Empty;
        public string CountryOfOrigin { get; init; } = string.Empty;
        public int DefaultWarehouseId { get; init; }
        public string WarehouseCode { get; init; } = string.Empty;
        public string WarehouseName { get; init; } = string.Empty;
        public int? WarrantyMonths { get; init; }
        public int MinQuantity { get; init; }
        public int? MaxQuantity { get; init; }
        public bool IsBivac { get; init; }
        public bool IsActive { get; init; }
        public string? BaseUnitSku { get; init; }
        public string? BaseUnitName { get; init; }
        public int OnHand { get; init; }
        public decimal? AverageCost { get; init; }
        public decimal? LastCost { get; init; }
        public int? DefaultSupplierId { get; init; }
        public string? DefaultSupplierName { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public int? CreatedBy { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public int? UpdatedBy { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public Item ToItem() => new()
        {
            Id = Id,
            ItemCode = ItemCode,
            ItemName = ItemName,
            BrandId = BrandId,
            BrandName = BrandName,
            Model = Model,
            ItemFamilyId = ItemFamilyId,
            FamilyCode = FamilyCode,
            FamilyName = FamilyName,
            CountryOfOrigin = CountryOfOrigin,
            DefaultWarehouseId = DefaultWarehouseId,
            WarehouseCode = WarehouseCode,
            WarehouseName = WarehouseName,
            WarrantyMonths = WarrantyMonths,
            MinQuantity = MinQuantity,
            MaxQuantity = MaxQuantity,
            IsBivac = IsBivac,
            IsActive = IsActive,
            BaseUnitSku = BaseUnitSku,
            BaseUnitName = BaseUnitName,
            OnHand = OnHand,
            AverageCost = AverageCost,
            LastCost = LastCost,
            DefaultSupplierId = DefaultSupplierId,
            DefaultSupplierName = DefaultSupplierName,
            CreatedAtUtc = CreatedAtUtc,
            CreatedBy = CreatedBy,
            UpdatedAtUtc = UpdatedAtUtc,
            UpdatedBy = UpdatedBy,
            RowVersion = RowVersion
        };
    }

    public async Task<(IReadOnlyList<Item> Items, int TotalCount)> SearchAsync(
        ItemQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            query.ItemFamilyId,
            query.BrandId,
            query.DefaultWarehouseId,
            query.IsActive,
            query.IsBivac,
            SortColumn = ResolveSortColumn(query.SortBy),
            SortDirection = ResolveSortDirection(query.SortDir),
            PageNumber = query.Page,
            query.PageSize
        };

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<ItemRow>(new CommandDefinition(
                "inventory.usp_Item_Search", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var list = rows.AsList();
            // The procedure repeats the same COUNT(*) OVER () on every row; no rows means nothing matched.
            var total = list.Count > 0 ? list[0].TotalCount : 0;
            return (list.Select(r => r.ToItem()).ToList(), total);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<(Item Item, IReadOnlyList<ItemUnit> Units, IReadOnlyList<ItemFile> Files)?> GetAsync(
        int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            // usp_Item_Get returns three result sets: the item, its units, its file metadata.
            await using var reader = await connection.QueryMultipleAsync(new CommandDefinition(
                "inventory.usp_Item_Get", new { Id = id },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var item = await reader.ReadSingleOrDefaultAsync<Item>();
            if (item is null)
            {
                return null;
            }

            var units = (await reader.ReadAsync<ItemUnit>()).AsList();
            var files = (await reader.ReadAsync<ItemFile>()).AsList();

            return (item, units, files);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<int> CreateAsync(Item item, int? userId, CancellationToken cancellationToken = default)
    {
        var parameters = BuildItemParameters(item);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_Item_Create", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var id = parameters.Get<int>("@NewId");
            item.Id = id;
            return id;
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task UpdateAsync(
        Item item, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default)
    {
        var parameters = BuildItemParameters(item);
        parameters.Add("@Id", item.Id, DbType.Int32);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_Item_Update", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task SetActiveAsync(
        int id, bool isActive, int? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_Item_SetActive", new { Id = id, IsActive = isActive, UserId = userId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task DeleteAsync(int id, int? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_Item_Delete", new { Id = id, UserId = userId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<IReadOnlyList<ItemLookup>> LookupAsync(
        bool activeOnly, int? includeId, bool salesOnly = false, bool bivacOnly = false,
        string? search = null, int? top = null, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters(new { ActiveOnly = activeOnly, IncludeId = includeId, SalesOnly = salesOnly });

        /* ONLY WHAT THE CALLER ASKED FOR. @BivacOnly exists from script 66 on: sent only when true, every
           other picker keeps working on a database that does not have it yet. @Search and @Top are left
           to the procedure's defaults unless given, so the limit a dropdown gets is decided in one place. */
        if (bivacOnly)
        {
            parameters.Add("@BivacOnly", true, DbType.Boolean);
        }

        if (!string.IsNullOrWhiteSpace(search))
        {
            parameters.Add("@Search", search.Trim(), DbType.String, size: 200);
        }

        if (top is { } limit)
        {
            parameters.Add("@Top", limit, DbType.Int32);
        }

        await using var connection = _connectionFactory.Create();
        try
        {
            var found = await connection.QueryAsync<ItemLookup>(new CommandDefinition(
                "inventory.usp_Item_Lookup", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            return found.AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    // ----- units -----

    public async Task<int> CreateUnitAsync(ItemUnit unit, int? userId, CancellationToken cancellationToken = default)
    {
        var parameters = BuildUnitParameters(unit);
        parameters.Add("@ItemId", unit.ItemId, DbType.Int32);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_ItemUnit_Create", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var id = parameters.Get<int>("@NewId");
            unit.Id = id;
            return id;
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task UpdateUnitAsync(
        ItemUnit unit, byte[]? rowVersion, int? userId, CancellationToken cancellationToken = default)
    {
        var parameters = BuildUnitParameters(unit);
        parameters.Add("@Id", unit.Id, DbType.Int32);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_ItemUnit_Update", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task DeleteUnitAsync(int unitId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_ItemUnit_Delete", new { Id = unitId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    // ----- files -----

    public async Task<int> AddFileAsync(
        ItemFile file, DocumentFileFields? fields, int? userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@ItemId", file.ItemId, DbType.Int32);
        parameters.Add("@FileName", file.FileName, DbType.String, size: 255);
        parameters.Add("@ContentType", file.ContentType, DbType.String, size: 100);
        parameters.Add("@SizeBytes", file.SizeBytes, DbType.Int32);
        parameters.Add("@IsItemImage", file.IsItemImage, DbType.Boolean);
        parameters.Add("@Content", file.Content, DbType.Binary, size: -1);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        AddFields(parameters, fields);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_ItemFile_Add", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var id = parameters.Get<int>("@NewId");
            file.Id = id;
            return id;
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<IReadOnlyList<ItemStockBalanceRowDto>> GetStockBalanceAsync(int itemId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<ItemStockBalanceRowDto>(new CommandDefinition(
            "inventory.usp_Item_StockBalance", new { ItemId = itemId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        return rows.AsList();
    }

    public async Task<IReadOnlyList<ItemContainerDto>> GetContainersAsync(int itemId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<ItemContainerDto>(new CommandDefinition(
            "inventory.usp_Item_Containers", new { ItemId = itemId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        return rows.AsList();
    }

    public async Task<IReadOnlyList<ItemPurchaseOrderDto>> GetPurchaseOrdersAsync(int itemId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<ItemPurchaseOrderDto>(new CommandDefinition(
            "inventory.usp_Item_PurchaseOrders", new { ItemId = itemId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        return rows.AsList();
    }

    public async Task<(int OpeningBase, IReadOnlyList<ItemStockMovementDto> Movements)> GetStockStatementAsync(
        int itemId, DateOnly? from, DateOnly? to, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        int opening;
        List<ItemStockMovementDto> movements;
        await using (var grid = await connection.QueryMultipleAsync(new CommandDefinition(
            "inventory.usp_Item_StockStatement",
            new
            {
                ItemId = itemId,
                DateFrom = from?.ToDateTime(TimeOnly.MinValue),
                DateTo = to?.ToDateTime(TimeOnly.MinValue),
            },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken)))
        {
            opening = await grid.ReadSingleAsync<int>();
            movements = (await grid.ReadAsync<ItemStockMovementDto>()).AsList();
        }

        await SetReceiptSourcesAsync(connection, movements, cancellationToken);
        return (opening, movements);
    }

    /// <summary>The ids behind a goods receipt row's SourceReference.</summary>
    private sealed class ReceiptSourceRow
    {
        public long Id { get; init; }
        public int? ContainerId { get; init; }
        public int? PurchaseOrderId { get; init; }
        public int? InvoiceId { get; init; }
    }

    /// <summary>
    /// (65) A GOODS RECEIPT ROW NAMES WHAT BROUGHT ITS GOODS ("GRN-BR-002-000001 · KTG-2026-0031") and the page links
    /// that name too: the ids behind SourceReference, by the procedure's own rule - the container, else the order (the
    /// line's, else the receipt's), else the invoice. Read here so the statement procedure keeps its columns.
    /// </summary>
    private static async Task SetReceiptSourcesAsync(
        SqlConnection connection, List<ItemStockMovementDto> movements, CancellationToken cancellationToken)
    {
        var rows = movements.Where(m => m.DocumentTypeCode == "GRN" && m.SourceReference is not null).ToList();
        if (rows.Count == 0)
        {
            return;
        }

        const string sql = """
            SELECT m.Id, gr.ContainerId,
                   PurchaseOrderId = CASE WHEN gr.ContainerId IS NULL THEN COALESCE(grl.PurchaseOrderId, gr.PurchaseOrderId) END,
                   InvoiceId = CASE WHEN gr.ContainerId IS NULL AND COALESCE(grl.PurchaseOrderId, gr.PurchaseOrderId) IS NULL
                                    THEN gr.PurchaseInvoiceId END
            FROM inventory.StockMovements m
            INNER JOIN purchase.GoodsReceipts gr     ON gr.Id = m.DocumentId
            LEFT  JOIN purchase.GoodsReceiptLines grl ON grl.Id = m.DocumentLineId AND grl.GoodsReceiptId = gr.Id
            WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'GRN' AND m.Id IN @Ids;
            """;

        // In chunks: an IN list is one parameter per id, and SQL Server takes at most 2,100 per command.
        var sources = new Dictionary<long, ReceiptSourceRow>();
        foreach (var chunk in rows.Select(r => r.Id).Chunk(1000))
        {
            foreach (var source in await connection.QueryAsync<ReceiptSourceRow>(
                         new CommandDefinition(sql, new { Ids = chunk }, cancellationToken: cancellationToken)))
            {
                sources[source.Id] = source;
            }
        }

        foreach (var row in rows)
        {
            if (sources.TryGetValue(row.Id, out var source))
            {
                row.SourceContainerId = source.ContainerId;
                row.SourcePurchaseOrderId = source.PurchaseOrderId;
                row.SourceInvoiceId = source.InvoiceId;
            }
        }
    }

    public async Task<ItemFile?> GetFileAsync(int fileId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            return await connection.QuerySingleOrDefaultAsync<ItemFile>(new CommandDefinition(
                "inventory.usp_ItemFile_Get", new { Id = fileId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<IReadOnlyList<DocumentFileDto>> ListFilesAsync(
        int itemId, int? attachmentTypeId = null, int? fileId = null, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<ItemFileRow>(new CommandDefinition(
                "inventory.usp_ItemFile_List", new { ItemId = itemId, AttachmentTypeId = attachmentTypeId, FileId = fileId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return rows.Select(r => r.ToDto(itemId)).ToList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<DocumentFileDto?> UpdateFileAsync(
        int fileId, string fileName, string? contentType, byte[]? content, DocumentFileFields? fields,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", fileId, DbType.Int32);
        parameters.Add("@FileName", fileName, DbType.String, size: 255);
        parameters.Add("@ContentType", contentType, DbType.String, size: 100);
        parameters.Add("@SizeBytes", content?.Length, DbType.Int32);
        parameters.Add("@Content", content, DbType.Binary, size: -1);
        AddFields(parameters, fields);

        await using var connection = _connectionFactory.Create();
        try
        {
            // Script 67 answers the document's row (usp_ItemFile_List's shape); the item is the file's own.
            var row = await connection.QuerySingleOrDefaultAsync<ItemFileRow>(new CommandDefinition(
                "inventory.usp_ItemFile_Update", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return row?.ToDto(row.DocumentId != 0 ? row.DocumentId : row.ItemId);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task DeleteFileAsync(int fileId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_ItemFile_Delete", new { Id = fileId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>
    /// The type / date / note of a document (script 67). ONLY SENT FOR A DOCUMENT: the picture has none, and
    /// leaving the parameters out keeps its upload the call it always was.
    /// </summary>
    private static void AddFields(DynamicParameters parameters, DocumentFileFields? fields)
    {
        if (fields is null)
        {
            return;
        }

        parameters.Add("@AttachmentTypeId", fields.AttachmentTypeId, DbType.Int32);
        parameters.Add("@DocumentDate", fields.DocumentDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@Note", fields.Note, DbType.String, size: 500);
    }

    /// <summary>
    /// One row of usp_ItemFile_List. The item is the "document" of the shared file shape, so DocumentId is the
    /// item's id whether the procedure names the column DocumentId or ItemId.
    /// </summary>
    private sealed class ItemFileRow
    {
        public int Id { get; init; }
        public int DocumentId { get; init; }
        public int ItemId { get; init; }
        public string FileName { get; init; } = string.Empty;
        public string ContentType { get; init; } = string.Empty;
        public int SizeBytes { get; init; }
        public int? AttachmentTypeId { get; init; }
        public string? Category { get; init; }
        public string? SubType { get; init; }
        public DateTime? DocumentDate { get; init; }
        public string? Note { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public int? CreatedBy { get; init; }
        public string? CreatedByName { get; init; }

        public DocumentFileDto ToDto(int itemId) => new()
        {
            Id = Id,
            DocumentId = itemId,
            FileName = FileName,
            ContentType = ContentType,
            SizeBytes = SizeBytes,
            AttachmentTypeId = AttachmentTypeId,
            Category = Category,
            SubType = SubType,
            DocumentDate = DocumentDate,
            Note = Note,
            CreatedAtUtc = CreatedAtUtc,
            CreatedBy = CreatedBy,
            CreatedByName = CreatedByName,
        };
    }

    public async Task SetPurchasingAsync(
        int id, int? defaultSupplierId, int? leadTimeDays, int? pcPerContainer, decimal? weightKg,
        decimal? volumeCbm, int? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_Item_SetPurchasing",
                new
                {
                    Id = id,
                    DefaultSupplierId = defaultSupplierId,
                    LeadTimeDays = leadTimeDays,
                    UserId = userId,
                    PcPerContainer = pcPerContainer,
                    WeightKg = weightKg,
                    VolumeCbm = volumeCbm,
                },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task SetNotesAsync(
        int id, string? note, string? link, int? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            var parameters = new DynamicParameters();
            parameters.Add("@Id", id, DbType.Int32);
            parameters.Add("@Note", note, DbType.String, size: 2000);
            parameters.Add("@Link", link, DbType.String, size: 500);
            parameters.Add("@UserId", userId, DbType.Int32);

            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_Item_SetNotes", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task SetLeadTimeAsync(int id, decimal? leadTimeMonths, int? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            var parameters = new DynamicParameters();
            parameters.Add("@Id", id, DbType.Int32);
            parameters.Add("@LeadTimeMonths", leadTimeMonths, DbType.Decimal, precision: 5, scale: 1);
            parameters.Add("@UserId", userId, DbType.Int32);
            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_Item_SetLeadTime", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task SetTrackingAsync(
        int id, Model.Enums.TrackingMode trackingMode, bool requiresExpiry, int? serialLength, int? userId,
        CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            var parameters = new DynamicParameters();
            parameters.Add("@Id", id, DbType.Int32);
            parameters.Add("@TrackingMode", (byte)trackingMode, DbType.Byte);
            parameters.Add("@RequiresExpiry", requiresExpiry, DbType.Boolean);
            // A length the TINYINT cannot hold goes as itself, refused by the procedure in its own words (1-50).
            parameters.Add("@SerialLength", serialLength is { } length ? (byte)Math.Clamp(length, 0, 255) : null, DbType.Byte);
            parameters.Add("@UserId", userId, DbType.Int32);

            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_Item_SetTracking", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    // ----- helpers -----

    /// <summary>The columns create and update share; the caller adds @Id / @RowVersion / @UserId / @NewId.</summary>
    private static DynamicParameters BuildItemParameters(Item item)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@ItemCode", item.ItemCode, DbType.String, size: 30);
        parameters.Add("@ItemName", item.ItemName, DbType.String, size: 200);
        parameters.Add("@BrandId", item.BrandId, DbType.Int32);
        parameters.Add("@Model", item.Model, DbType.String, size: 100);
        parameters.Add("@ItemFamilyId", item.ItemFamilyId, DbType.Int32);
        parameters.Add("@CountryOfOrigin", item.CountryOfOrigin, DbType.String, size: 2);
        parameters.Add("@DefaultWarehouseId", item.DefaultWarehouseId, DbType.Int32);
        parameters.Add("@Description", item.Description, DbType.String, size: 1000);
        parameters.Add("@WarrantyMonths", item.WarrantyMonths, DbType.Int32);
        parameters.Add("@MinQuantity", item.MinQuantity, DbType.Int32);
        parameters.Add("@MaxQuantity", item.MaxQuantity, DbType.Int32);
        parameters.Add("@IsBivac", item.IsBivac, DbType.Boolean);
        parameters.Add("@IsActive", item.IsActive, DbType.Boolean);
        return parameters;
    }

    /// <summary>The columns unit create and update share; the caller adds @ItemId or @Id / @RowVersion.</summary>
    private static DynamicParameters BuildUnitParameters(ItemUnit unit)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@UnitTypeId", unit.UnitTypeId, DbType.Int32);
        parameters.Add("@PackingFormula", unit.PackingFormula, DbType.Int32);
        parameters.Add("@SkuCode", unit.SkuCode, DbType.String, size: 50);
        parameters.Add("@Barcode", unit.Barcode, DbType.String, size: 50);
        parameters.Add("@IsSalesUnit", unit.IsSalesUnit, DbType.Boolean);
        parameters.Add("@IsPurchaseUnit", unit.IsPurchaseUnit, DbType.Boolean);
        parameters.Add("@IsBaseUnit", unit.IsBaseUnit, DbType.Boolean);
        parameters.Add("@LengthCm", unit.LengthCm, DbType.Decimal, precision: 10, scale: 2);
        parameters.Add("@WidthCm", unit.WidthCm, DbType.Decimal, precision: 10, scale: 2);
        parameters.Add("@HeightCm", unit.HeightCm, DbType.Decimal, precision: 10, scale: 2);
        parameters.Add("@WeightKg", unit.WeightKg, DbType.Decimal, precision: 12, scale: 3);
        return parameters;
    }

    private static string ResolveSortColumn(string? sortBy)
        => SortColumns.FirstOrDefault(c => string.Equals(c, sortBy, StringComparison.OrdinalIgnoreCase))
           ?? "ItemCode";

    private static string ResolveSortDirection(string? sortDir)
        => string.Equals(sortDir, "desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC";
}
