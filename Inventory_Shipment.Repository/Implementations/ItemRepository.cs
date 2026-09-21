using System.Data;
using Dapper;
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

    public async Task DeleteAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inventory.usp_Item_Delete", new { Id = id },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<IReadOnlyList<ItemLookup>> LookupAsync(
        bool activeOnly, int? includeId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<ItemLookup>(new CommandDefinition(
                "inventory.usp_Item_Lookup", new { ActiveOnly = activeOnly, IncludeId = includeId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            return rows.AsList();
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

    public async Task<int> AddFileAsync(ItemFile file, int? userId, CancellationToken cancellationToken = default)
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
        return parameters;
    }

    private static string ResolveSortColumn(string? sortBy)
        => SortColumns.FirstOrDefault(c => string.Equals(c, sortBy, StringComparison.OrdinalIgnoreCase))
           ?? "ItemCode";

    private static string ResolveSortDirection(string? sortDir)
        => string.Equals(sortDir, "desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC";
}
