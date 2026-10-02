using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Logistics;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class ContainerRepository : IContainerRepository
{
    /// <summary>Matched by TYPE NAME on the server; a wrong one fails with a message that never mentions the type.</summary>
    private const string LineTypeName = "logistics.tvp_ContainerLoadLine";
    private const string IdListTypeName = "logistics.tvp_IdList";
    private const string ReceiptTypeName = "logistics.tvp_ContainerReceipt";
    private const string PlanLineTypeName = "logistics.tvp_ContainerPlanLine";
    private const string ItemCapacityTypeName = "logistics.tvp_ItemCapacity";
    private const string ContainerNumberTypeName = "logistics.tvp_ContainerNumber";

    /// <summary>The columns the search procedure will sort by; anything else falls back to the order date.</summary>
    private static readonly string[] SortColumns =
        ["ContainerRef", "ContainerNo", "OrderDate", "DispatchDate", "Eta", "Status", "CreatedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public ContainerRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    /// <summary>The list row plus the window count the procedure adds. Serialized as the base type, so the count stays out of the JSON.</summary>
    private sealed record ListRow : ContainerListDto
    {
        public int TotalCount { get; init; }
    }

    public async Task<(IReadOnlyList<ContainerListDto> Items, int TotalCount)> SearchAsync(
        ContainerQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = Trimmed(query.Search),
            ContainerRef = Trimmed(query.ContainerRef),
            ContainerNo = Trimmed(query.ContainerNo),
            query.SupplierId,
            query.PurchaseDocumentId,
            query.PurchaseOrderId,
            CommercialInvoiceNo = Trimmed(query.CommercialInvoiceNo),
            query.ItemId,
            BlNo = Trimmed(query.BlNo),
            Status = ContainerStatus.ToCode(query.Status),
            query.PortId,
            query.WarehouseId,
            query.BranchId,
            query.MovementId,
            query.OrderMonthKey,
            DateFrom = query.DateFrom?.ToDateTime(TimeOnly.MinValue),
            DateTo = query.DateTo?.ToDateTime(TimeOnly.MinValue),
            SortColumn = SortColumns.FirstOrDefault(c => string.Equals(c, query.SortBy, StringComparison.OrdinalIgnoreCase)) ?? "OrderDate",
            SortDirection = string.Equals(query.SortDir, "asc", StringComparison.OrdinalIgnoreCase) ? "ASC" : "DESC",
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        var rows = (await connection.QueryAsync<ListRow>(new CommandDefinition(
            "logistics.usp_Container_Search", parameters,
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))).AsList();

        var total = rows.Count > 0 ? rows[0].TotalCount : 0;
        return (rows, total);
    }

    public async Task<ContainerDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();

        // Eight result sets in one round trip, so the capacity on the header, the lines under it and
        // the charges split over them are from the same moment — a line saved between two reads
        // would make the bar disagree with the grid.
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "logistics.usp_Container_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var header = await multi.ReadSingleOrDefaultAsync<ContainerDto>();
        if (header is null)
        {
            return null;
        }

        var lines = (await multi.ReadAsync<ContainerLineDto>()).AsList();
        var invoices = (await multi.ReadAsync<ContainerInvoiceDto>()).AsList();
        var movements = (await multi.ReadAsync<ContainerMovementDto>()).AsList();
        var charges = (await multi.ReadAsync<ContainerChargeRowDto>()).AsList();
        var allocations = (await multi.ReadAsync<ContainerChargeAllocationDto>()).AsList();
        var attachments = (await multi.ReadAsync<ContainerAttachmentDto>()).AsList();
        var audit = (await multi.ReadAsync<ContainerAuditDto>()).AsList();

        return header with
        {
            Lines = lines,
            Invoices = invoices,
            Movements = movements,
            Charges = charges,
            Allocations = allocations,
            Attachments = attachments,
            Audit = audit,
        };
    }

    /// <summary>Three columns rather than the six result sets of the Get: this runs before every action.</summary>
    public async Task<ContainerStub?> GetStubAsync(int id, CancellationToken cancellationToken = default)
    {
        const string sql = "SELECT Id, ContainerRef, Status FROM logistics.Containers WHERE Id = @Id;";

        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<ContainerStub>(new CommandDefinition(
            sql, new { Id = id }, cancellationToken: cancellationToken));
    }

    public async Task<IReadOnlyList<AvailablePoLineDto>> GetAvailablePoLinesAsync(
        AvailablePoLineQuery query, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<AvailablePoLineDto>(new CommandDefinition(
            "logistics.usp_Container_AvailablePoLines",
            new { query.PurchaseOrderId, query.SupplierId, Search = Trimmed(query.Search), query.ContainerId, query.Top },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return rows.AsList();
    }

    /// <summary>69000 when neither an order nor a container is given — the service asks for one first.</summary>
    public async Task<IReadOnlyList<InvoiceCandidateDto>> GetInvoiceCandidatesAsync(
        InvoiceCandidateQuery query, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<InvoiceCandidateDto>(new CommandDefinition(
                "logistics.usp_Container_InvoiceCandidates",
                new { query.PurchaseOrderId, query.ContainerId, query.IncludeAll },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return rows.AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<TrackingDto> GetTrackingAsync(TrackingQuery query, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "logistics.usp_Container_Tracking",
            new { query.ContainerId, Search = Trimmed(query.Search), query.OffloadedDays },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var containers = (await multi.ReadAsync<TrackingContainerDto>()).AsList();
        var legs = (await multi.ReadAsync<TrackingLegDto>()).AsList();
        return new TrackingDto { Containers = containers, Legs = legs };
    }

    public async Task<ContainerAttachmentFile?> GetAttachmentFileAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<ContainerAttachmentFile>(new CommandDefinition(
            "logistics.usp_ContainerAttachment_GetFile", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<int> SaveAsync(
        SaveContainerRequest request, int? id, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = SaveParameters(request, id, userId);

        try
        {
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.ExecuteAsync(new CommandDefinition(
                    "logistics.usp_Container_Save", parameters,
                    commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            }, cancellationToken);

            return parameters.Get<int>("@NewId");
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>
    /// The parameters of logistics.usp_Container_Save (@NewId is the output), shared with the invoice that adds a
    /// container and links it in one transaction (script 43, which adds <c>@ForInvoiceId</c> to them).
    /// </summary>
    internal static DynamicParameters SaveParameters(SaveContainerRequest request, int? id, int userId)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@PurchaseOrderId", request.PurchaseOrderId, DbType.Int32);
        parameters.Add("@ContainerNo", request.ContainerNo, DbType.String, size: 20);
        parameters.Add("@ContainerTypeId", request.ContainerTypeId, DbType.Int32);
        parameters.Add("@SealNo", request.SealNo, DbType.String, size: 30);
        parameters.Add("@CustomsSealNo", request.CustomsSealNo, DbType.String, size: 30);
        parameters.Add("@Description", request.Description, DbType.String, size: 500);
        parameters.Add("@OrderDate", request.OrderDate.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@ShippingMethod", ShippingMethods.Normalize(request.ShippingMethod) ?? request.ShippingMethod, DbType.String, size: 10);
        parameters.Add("@CountryOfOrigin", Trimmed(request.CountryOfOrigin)?.ToUpperInvariant(), DbType.StringFixedLength, size: 2);
        parameters.Add("@ForwarderId", request.ForwarderId, DbType.Int32);
        parameters.Add("@TransporterId", request.TransporterId, DbType.Int32);
        parameters.Add("@ShippingLine", request.ShippingLine, DbType.String, size: 100);
        parameters.Add("@VesselName", request.VesselName, DbType.String, size: 100);
        parameters.Add("@VoyageNo", request.VoyageNo, DbType.String, size: 30);
        parameters.Add("@BookingNo", request.BookingNo, DbType.String, size: 30);
        parameters.Add("@PortOfLoadingId", request.PortOfLoadingId, DbType.Int32);
        parameters.Add("@PortOfDestinationId", request.PortOfDestinationId, DbType.Int32);
        parameters.Add("@FinalDestinationId", request.FinalDestinationId, DbType.Int32);
        parameters.Add("@DispatchDate", ToDate(request.DispatchDate), DbType.Date);
        parameters.Add("@Eta", ToDate(request.Eta), DbType.Date);
        parameters.Add("@FreeDays", request.FreeDays, DbType.Int32);
        parameters.Add("@GrossWeightKg", request.GrossWeightKg, DbType.Decimal, precision: 18, scale: 3);
        parameters.Add("@VolumeCbm", request.VolumeCbm, DbType.Decimal, precision: 18, scale: 3);
        parameters.Add("@Packages", request.Packages, DbType.Int32);
        parameters.Add("@BlNo", request.BlNo, DbType.String, size: 30);
        parameters.Add("@BlDate", ToDate(request.BlDate), DbType.Date);
        parameters.Add("@BlNotes", request.BlNotes, DbType.String, size: 500);
        parameters.Add("@MaxUnits", request.MaxUnits, DbType.Int32);
        parameters.Add("@BranchId", request.BranchId, DbType.Int32);
        parameters.Add("@WarehouseId", request.WarehouseId, DbType.Int32);
        parameters.Add("@TruckNo", request.TruckNo, DbType.String, size: 30);
        parameters.Add("@WaybillNo", request.WaybillNo, DbType.String, size: 30);
        parameters.Add("@DeclarationNo", request.DeclarationNo, DbType.String, size: 30);
        parameters.Add("@FeriNo", request.FeriNo, DbType.String, size: 30);
        parameters.Add("@ActualPortArrival", ToDate(request.ActualPortArrival), DbType.Date);
        parameters.Add("@BorderCrossingDate", ToDate(request.BorderCrossingDate), DbType.Date);
        parameters.Add("@CustomsReleaseDate", ToDate(request.CustomsReleaseDate), DbType.Date);
        parameters.Add("@StatusNote", request.StatusNote, DbType.String, size: 200);
        parameters.Add("@Notes", request.Notes, DbType.String, size: 1000);
        parameters.Add("@Lines", ToLineTable(request.Lines).AsTableValuedParameter(LineTypeName));
        parameters.Add("@AllowOverCapacity", request.AllowOverCapacity, DbType.Boolean);
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        return parameters;
    }

    public Task ConfirmAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_Container_Confirm",
            new { Id = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    /// <summary>An EMPTY table is the procedure's "everything received as loaded"; the table is sent either way, never null.</summary>
    public Task OffloadAsync(
        int id, OffloadRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@Lines", ToReceiptTable(request.Lines).AsTableValuedParameter(ReceiptTypeName));
        parameters.Add("@OffloadedDate", ToDate(request.OffloadedDate), DbType.Date);
        parameters.Add("@WarehouseId", request.WarehouseId, DbType.Int32);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);

        return ExecuteAsync("logistics.usp_Container_Offload", parameters, cancellationToken);
    }

    public Task CancelOffloadAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_Container_CancelOffload",
            new { Id = id, Reason = reason, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task CloseAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_Container_Close",
            new { Id = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task ReopenAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_Container_Reopen",
            new { Id = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_Container_Cancel",
            new { Id = id, Reason = reason, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_Container_Delete", new { Id = id, UserId = userId }, cancellationToken);

    public async Task<IReadOnlyList<ContainerAttachmentCreatedDto>> AddAttachmentAsync(
        ContainerAttachmentUpload upload, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@ContainerIds", MovementRepository.ToIdTable(upload.ContainerIds).AsTableValuedParameter(IdListTypeName));
        parameters.Add("@MovementId", upload.MovementId, DbType.Int32);
        parameters.Add("@ChargeId", upload.ChargeId, DbType.Int32);
        parameters.Add("@AttachmentTypeId", upload.AttachmentTypeId, DbType.Int32);
        parameters.Add("@FileName", upload.FileName, DbType.String, size: 255);
        parameters.Add("@ContentType", upload.ContentType, DbType.String, size: 100);
        parameters.Add("@SizeBytes", upload.Content.Length, DbType.Int32);
        parameters.Add("@Content", upload.Content, DbType.Binary, size: -1);
        parameters.Add("@Note", upload.Note, DbType.String, size: 300);
        parameters.Add("@DocumentDate", ToDate(upload.DocumentDate), DbType.Date);
        parameters.Add("@UserId", userId, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<ContainerAttachmentCreatedDto>(new CommandDefinition(
                "logistics.usp_ContainerAttachment_Add", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return rows.AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public Task DeleteAttachmentAsync(int id, bool allShared, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_ContainerAttachment_Delete",
            new { Id = id, AllShared = allShared, UserId = userId }, cancellationToken);

    /* ── many containers per order (script 28) ────────────────────────────────────────────────── */

    public async Task<AutoPlanDto> PlanFromOrderAsync(AutoPlanRequest request, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@PurchaseOrderId", request.PurchaseOrderId, DbType.Int32);
        parameters.Add("@ContainerTypeId", request.ContainerTypeId, DbType.Int32);
        parameters.Add("@MixRemainders", request.MixRemainders, DbType.Boolean);
        parameters.Add("@Capacities", ToCapacityTable(request.Capacities).AsTableValuedParameter(ItemCapacityTypeName));
        parameters.Add("@ForInvoiceId", request.ForInvoiceId, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        try
        {
            using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
                "logistics.usp_Container_PlanFromOrder", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var containers = (await multi.ReadAsync<PlannedContainerDto>()).AsList();
            var lines = (await multi.ReadAsync<PlannedContainerLineDto>()).AsList();
            var orderLines = (await multi.ReadAsync<PlanOrderLineDto>()).AsList();
            return new AutoPlanDto { Containers = containers, Lines = lines, OrderLines = orderLines };
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<IReadOnlyList<CreatedContainerDto>> CreateBatchAsync(
        CreateContainersFromPlanRequest request, int userId, CancellationToken cancellationToken = default)
        => await QueryAsync<CreatedContainerDto>("logistics.usp_Container_CreateBatch", CreateBatchParameters(request, userId), cancellationToken);

    /// <summary>The parameters of logistics.usp_Container_CreateBatch, shared like <see cref="SaveParameters"/>.</summary>
    internal static DynamicParameters CreateBatchParameters(CreateContainersFromPlanRequest request, int userId)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@PurchaseOrderId", request.PurchaseOrderId, DbType.Int32);
        parameters.Add("@ContainerTypeId", request.ContainerTypeId, DbType.Int32);
        parameters.Add("@OrderDate", ToDate(request.OrderDate), DbType.Date);
        parameters.Add("@BranchId", request.BranchId, DbType.Int32);
        parameters.Add("@WarehouseId", request.WarehouseId, DbType.Int32);

        // Left out when not given, so the procedure's own default (Sea) applies.
        if (request.ShippingMethod is not null)
        {
            parameters.Add("@ShippingMethod", ShippingMethods.Normalize(request.ShippingMethod) ?? request.ShippingMethod, DbType.String, size: 10);
        }

        parameters.Add("@CountryOfOrigin", Trimmed(request.CountryOfOrigin)?.ToUpperInvariant(), DbType.StringFixedLength, size: 2);
        parameters.Add("@ForwarderId", request.ForwarderId, DbType.Int32);
        parameters.Add("@ShippingLine", Trimmed(request.ShippingLine), DbType.String, size: 100);
        parameters.Add("@PortOfLoadingId", request.PortOfLoadingId, DbType.Int32);
        parameters.Add("@PortOfDestinationId", request.PortOfDestinationId, DbType.Int32);
        parameters.Add("@FinalDestinationId", request.FinalDestinationId, DbType.Int32);
        parameters.Add("@Eta", ToDate(request.Eta), DbType.Date);
        parameters.Add("@FreeDays", request.FreeDays, DbType.Int32);
        parameters.Add("@Plan", ToPlanTable(request.Containers).AsTableValuedParameter(PlanLineTypeName));
        parameters.Add("@Capacities", ToCapacityTable(request.Capacities).AsTableValuedParameter(ItemCapacityTypeName));
        parameters.Add("@AllowOverCapacity", request.AllowOverCapacity, DbType.Boolean);
        parameters.Add("@Confirm", request.Confirm, DbType.Boolean);
        parameters.Add("@UserId", userId, DbType.Int32);
        return parameters;
    }

    public Task<IReadOnlyList<ContainerNumberDto>> SetNumbersAsync(
        IReadOnlyList<ContainerNumberRequest> items, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Items", ToNumberTable(items).AsTableValuedParameter(ContainerNumberTypeName));
        parameters.Add("@UserId", userId, DbType.Int32);

        return QueryAsync<ContainerNumberDto>("logistics.usp_Container_SetNumbers", parameters, cancellationToken);
    }

    public Task<IReadOnlyList<ContainerConfirmedDto>> ConfirmManyAsync(
        IReadOnlyList<int> ids, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Ids", MovementRepository.ToIdTable(ids).AsTableValuedParameter(IdListTypeName));
        parameters.Add("@UserId", userId, DbType.Int32);

        return QueryAsync<ContainerConfirmedDto>("logistics.usp_Container_ConfirmMany", parameters, cancellationToken);
    }

    public async Task<int> DeleteManyAsync(IReadOnlyList<int> ids, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Ids", MovementRepository.ToIdTable(ids).AsTableValuedParameter(IdListTypeName));
        parameters.Add("@UserId", userId, DbType.Int32);

        var rows = await QueryAsync<ContainersDeletedDto>("logistics.usp_Container_DeleteMany", parameters, cancellationToken);
        return rows.Count > 0 ? rows[0].Deleted : 0;
    }

    /// <summary>A write that answers with rows: all or nothing in the procedure, so a deadlock victim is simply run again.</summary>
    private async Task<IReadOnlyList<T>> QueryAsync<T>(string procedure, DynamicParameters parameters, CancellationToken cancellationToken)
    {
        try
        {
            return await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                var rows = await connection.QueryAsync<T>(new CommandDefinition(
                    procedure, parameters, commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
                return (IReadOnlyList<T>)rows.AsList();
            }, cancellationToken);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>
    /// One procedure call, run again if SQL Server made it the deadlock victim: the offload and its
    /// reversal touch the ledger, the item costs and the invoice lines of every supplier on board.
    /// </summary>
    private async Task ExecuteAsync(string procedure, object parameters, CancellationToken cancellationToken)
    {
        try
        {
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.ExecuteAsync(new CommandDefinition(
                    procedure, parameters, commandType: CommandType.StoredProcedure,
                    cancellationToken: cancellationToken));
            }, cancellationToken);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /* ── plumbing ─────────────────────────────────────────────────────────────────────────────── */

    /* COLUMN ORDER IS THE TYPE'S ORDER AND IS LOAD-BEARING — a table-valued parameter is sent
       positionally. Each table below repeats its CREATE TYPE from scripts 24 / 27 / 28 column by column; types
       are declared, not inferred, because an all-null column infers as string and the server
       refuses the batch. */

    /// <summary>logistics.tvp_ContainerLoadLine (LineNumber, PoLineId, QuantityBase, OilIncluded, OilQtyPerUnit, Notes).</summary>
    private static DataTable ToLineTable(IReadOnlyList<SaveContainerLineRequest> lines)
    {
        var table = new DataTable();
        table.Columns.Add("LineNumber", typeof(int));
        table.Columns.Add("PoLineId", typeof(int));
        table.Columns.Add("QuantityBase", typeof(int));
        table.Columns.Add("OilIncluded", typeof(bool));
        table.Columns.Add("OilQtyPerUnit", typeof(decimal));
        table.Columns.Add("Notes", typeof(string));

        // Numbered from the position in the list, not from what the client sent — one authority.
        var lineNumber = 1;
        foreach (var line in lines)
        {
            table.Rows.Add(
                lineNumber++,
                line.PoLineId,
                line.QuantityBase,
                line.OilIncluded,
                (object?)line.OilQtyPerUnit ?? DBNull.Value,
                (object?)line.Notes ?? DBNull.Value);
        }

        return table;
    }

    /// <summary>logistics.tvp_ContainerReceipt (LineId, ReceivedQuantityBase, VarianceReason).</summary>
    private static DataTable ToReceiptTable(IReadOnlyList<OffloadLineRequest> lines)
    {
        var table = new DataTable();
        table.Columns.Add("LineId", typeof(int));
        table.Columns.Add("ReceivedQuantityBase", typeof(int));
        table.Columns.Add("VarianceReason", typeof(string));
        foreach (var line in lines)
        {
            table.Rows.Add(line.LineId, line.ReceivedQuantityBase, (object?)line.VarianceReason ?? DBNull.Value);
        }

        return table;
    }

    /// <summary>logistics.tvp_ContainerPlanLine (Seq, PoLineId, QuantityBase, OilIncluded) — containers[].lines[] flattened.</summary>
    private static DataTable ToPlanTable(IReadOnlyList<PlanContainerRequest> containers)
    {
        var table = new DataTable();
        table.Columns.Add("Seq", typeof(int));
        table.Columns.Add("PoLineId", typeof(int));
        table.Columns.Add("QuantityBase", typeof(int));
        table.Columns.Add("OilIncluded", typeof(bool));
        foreach (var container in containers)
        {
            foreach (var line in container.Lines)
            {
                table.Rows.Add(container.Seq, line.PoLineId, line.QuantityBase, (object?)line.OilIncluded ?? DBNull.Value);
            }
        }

        return table;
    }

    /// <summary>logistics.tvp_ItemCapacity (ItemId, PcsPerContainer); empty when none was typed.</summary>
    private static DataTable ToCapacityTable(IReadOnlyList<ItemCapacityRequest>? capacities)
    {
        var table = new DataTable();
        table.Columns.Add("ItemId", typeof(int));
        table.Columns.Add("PcsPerContainer", typeof(int));
        foreach (var capacity in capacities ?? [])
        {
            table.Rows.Add(capacity.ItemId, capacity.PcsPerContainer);
        }

        return table;
    }

    /// <summary>logistics.tvp_ContainerNumber (ContainerId, ContainerNo, SealNo).</summary>
    private static DataTable ToNumberTable(IReadOnlyList<ContainerNumberRequest> items)
    {
        var table = new DataTable();
        table.Columns.Add("ContainerId", typeof(int));
        table.Columns.Add("ContainerNo", typeof(string));
        table.Columns.Add("SealNo", typeof(string));
        foreach (var item in items)
        {
            table.Rows.Add(item.ContainerId, (object?)item.ContainerNo ?? DBNull.Value, (object?)item.SealNo ?? DBNull.Value);
        }

        return table;
    }

    private static string? Trimmed(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private static DateTime? ToDate(DateOnly? value) => value?.ToDateTime(TimeOnly.MinValue);

    private static byte[]? ToRowVersion(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return Convert.TryFromBase64String(value, new byte[8], out var written) && written == 8
            ? Convert.FromBase64String(value)
            : null;
    }
}
