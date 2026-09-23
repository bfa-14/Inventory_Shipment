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
    private const string InvoiceTypeName = "logistics.tvp_ContainerInvoice";
    private const string LineTypeName = "logistics.tvp_ContainerLine";
    private const string ReceiptTypeName = "logistics.tvp_ContainerReceipt";

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
            CommercialInvoiceNo = Trimmed(query.CommercialInvoiceNo),
            query.ItemId,
            BlNo = Trimmed(query.BlNo),
            Status = ContainerStatus.ToCode(query.Status),
            query.PortId,
            query.WarehouseId,
            query.BranchId,
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

        // Six result sets in one round trip, so the capacity on the header and the lines under it are
        // from the same moment — a line saved between two reads would make the bar disagree with the grid.
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "logistics.usp_Container_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var header = await multi.ReadSingleOrDefaultAsync<ContainerDto>();
        if (header is null)
        {
            return null;
        }

        var invoices = (await multi.ReadAsync<ContainerInvoiceDto>()).AsList();
        var lines = (await multi.ReadAsync<ContainerLineDto>()).AsList();
        var events = (await multi.ReadAsync<ContainerEventDto>()).AsList();
        var files = (await multi.ReadAsync<ContainerFileDto>()).AsList();
        var audit = (await multi.ReadAsync<ContainerAuditDto>()).AsList();

        return header with
        {
            Invoices = invoices,
            Lines = lines,
            Events = events,
            Files = files,
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

    public async Task<IReadOnlyList<AvailableInvoiceDto>> GetAvailableInvoicesAsync(
        AvailableInvoiceQuery query, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<AvailableInvoiceDto>(new CommandDefinition(
            "logistics.usp_Container_AvailableInvoices",
            new { Search = Trimmed(query.Search), query.SupplierId, query.ContainerId, query.Top },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return rows.AsList();
    }

    /// <summary>
    /// The loading grid of one invoice. NOT A PROCEDURE because none answers it: usp_PurchaseDocument_Get
    /// counts this container's own allocation as "allocated", which is wrong for the container being
    /// edited, and it has no model or oil figure. The rules match logistics.usp_Container_Save — what
    /// cancelled containers hold is free, what this container holds is its own.
    /// </summary>
    public async Task<IReadOnlyList<AvailableInvoiceLineDto>?> GetInvoiceLinesAsync(
        int invoiceId, int? containerId, CancellationToken cancellationToken = default)
    {
        const string sql = """
            SELECT CAST(CASE WHEN EXISTS (SELECT 1 FROM purchase.PurchaseDocuments d
                                          INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId
                                          WHERE d.Id = @InvoiceId AND dt.Code = N'PINV') THEN 1 ELSE 0 END AS BIT);

            SELECT PurchaseLineId = pl.Id, PurchaseDocumentId = pl.DocumentId, pl.LineNumber,
                   pl.ItemId, i.ItemCode, i.ItemName, i.Model, pl.ItemUnitId, ut.UnitTypeName, pl.PackingFormula,
                   pl.Quantity, pl.QuantityBase,
                   AllocatedElsewhereBase = ISNULL(o.Qty, 0),
                   AllocatedHereBase      = ISNULL(h.Qty, 0),
                   AvailableBase          = pl.QuantityBase - ISNULL(o.Qty, 0),
                   i.OilQtyPerUnit
            FROM purchase.PurchaseDocumentLines pl
            INNER JOIN inventory.Items i        ON i.Id = pl.ItemId
            INNER JOIN inventory.ItemUnits iu   ON iu.Id = pl.ItemUnitId
            INNER JOIN masterdata.UnitTypes ut  ON ut.Id = iu.UnitTypeId
            OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                         INNER JOIN logistics.Containers c ON c.Id = cl.ContainerId
                         WHERE cl.PurchaseLineId = pl.Id AND c.Status <> 8
                           AND (@ContainerId IS NULL OR cl.ContainerId <> @ContainerId)) o
            OUTER APPLY (SELECT Qty = SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                         WHERE cl.PurchaseLineId = pl.Id AND cl.ContainerId = @ContainerId) h
            WHERE pl.DocumentId = @InvoiceId
            ORDER BY pl.LineNumber;
            """;

        await using var connection = _connectionFactory.Create();
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            sql, new { InvoiceId = invoiceId, ContainerId = containerId }, cancellationToken: cancellationToken));

        var isInvoice = await multi.ReadSingleAsync<bool>();
        var lines = (await multi.ReadAsync<AvailableInvoiceLineDto>()).AsList();
        return isInvoice ? lines : null;
    }

    public async Task<ContainerFileContent?> GetFileAsync(int fileId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<ContainerFileContent>(new CommandDefinition(
            "logistics.usp_ContainerFile_Get", new { Id = fileId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<int> SaveAsync(
        SaveContainerRequest request, int? id, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
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
        parameters.Add("@Invoices", ToInvoiceTable(request.Invoices).AsTableValuedParameter(InvoiceTypeName));
        parameters.Add("@Lines", ToLineTable(request.Lines).AsTableValuedParameter(LineTypeName));
        parameters.Add("@AllowOverCapacity", request.AllowOverCapacity, DbType.Boolean);
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

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

    public Task ConfirmAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_Container_Confirm",
            new { Id = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task AddEventAsync(int id, AddEventRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@ContainerId", id, DbType.Int32);
        parameters.Add("@EventType", ContainerEventTypes.Normalize(request.EventType) ?? request.EventType, DbType.String, size: 20);
        parameters.Add("@EventDate", request.EventDate.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@PortId", request.PortId, DbType.Int32);
        parameters.Add("@LocationText", request.LocationText, DbType.String, size: 100);
        parameters.Add("@Notes", request.Notes, DbType.String, size: 300);
        parameters.Add("@UserId", userId, DbType.Int32);

        return ExecuteAsync("logistics.usp_Container_AddEvent", parameters, cancellationToken);
    }

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

    public Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_Container_Cancel",
            new { Id = id, Reason = reason, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_Container_Delete", new { Id = id, UserId = userId }, cancellationToken);

    public async Task<int> AddFileAsync(
        int containerId, ContainerFileUpload upload, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@ContainerId", containerId, DbType.Int32);
        parameters.Add("@AttachmentTypeId", upload.AttachmentTypeId, DbType.Int32);
        parameters.Add("@FileName", upload.FileName, DbType.String, size: 255);
        parameters.Add("@ContentType", upload.ContentType, DbType.String, size: 100);
        parameters.Add("@SizeBytes", upload.Content.Length, DbType.Int32);
        parameters.Add("@Content", upload.Content, DbType.Binary, size: -1);
        parameters.Add("@Note", upload.Note, DbType.String, size: 300);
        parameters.Add("@DocumentDate", ToDate(upload.DocumentDate), DbType.Date);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "logistics.usp_ContainerFile_Add", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return parameters.Get<int>("@NewId");
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public Task DeleteFileAsync(int fileId, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("logistics.usp_ContainerFile_Delete", new { Id = fileId, UserId = userId }, cancellationToken);

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
       positionally. Each table below repeats its CREATE TYPE from script 24 column by column; types
       are declared, not inferred, because an all-null column infers as string and the server
       refuses the batch. */

    /// <summary>logistics.tvp_ContainerInvoice (PurchaseDocumentId). Duplicates dropped: the column is the primary key.</summary>
    private static DataTable ToInvoiceTable(IReadOnlyList<int> invoiceIds)
    {
        var table = new DataTable();
        table.Columns.Add("PurchaseDocumentId", typeof(int));
        foreach (var invoiceId in invoiceIds.Distinct())
        {
            table.Rows.Add(invoiceId);
        }

        return table;
    }

    /// <summary>logistics.tvp_ContainerLine (LineNumber, PurchaseLineId, Quantity, OilIncluded, OilQtyPerUnit, Notes).</summary>
    private static DataTable ToLineTable(IReadOnlyList<SaveContainerLineRequest> lines)
    {
        var table = new DataTable();
        table.Columns.Add("LineNumber", typeof(int));
        table.Columns.Add("PurchaseLineId", typeof(int));
        table.Columns.Add("Quantity", typeof(int));
        table.Columns.Add("OilIncluded", typeof(bool));
        table.Columns.Add("OilQtyPerUnit", typeof(decimal));
        table.Columns.Add("Notes", typeof(string));

        // Numbered from the position in the list, not from what the client sent — one authority.
        var lineNumber = 1;
        foreach (var line in lines)
        {
            table.Rows.Add(
                lineNumber++,
                line.PurchaseLineId,
                line.Quantity,
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
