using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Purchase;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

/// <summary>
/// Goods receipts over script 64's procedures. The "receive goods" dialogs read the procedures' own figures
/// (purchase.fn_PoLine_Progress, fn_InvoiceLine_ToReceive, logistics.fn_Container_ReceivedBy / _LastDelivery) with
/// plain queries: what a dialog proposes and what posting caps are then one formula, written once in SQL.
/// </summary>
public sealed class GoodsReceiptRepository : IGoodsReceiptRepository
{
    /// <summary>Matched by TYPE NAME on the server. FROZEN in script 64: a later change takes a new name.</summary>
    private const string LineTypeName = "purchase.tvp_GoodsReceiptLine";

    /// <summary>The columns the search procedure sorts by; anything else falls back to the date received.</summary>
    private static readonly string[] SortColumns =
        ["DocumentNumber", "DocumentDate", "SupplierName", "Status", "ReceivedBase", "ValueBase", "CreatedAtUtc", "PostedAtUtc"];

    private readonly ISqlConnectionFactory _connectionFactory;

    public GoodsReceiptRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /* ── reading ──────────────────────────────────────────────────────────────────────────────── */

    /// <summary>The list row and the paging total, as the procedure returns them.</summary>
    private sealed class ListRow
    {
        public int Id { get; init; }
        public string? DocumentNumber { get; init; }
        public DateTime DocumentDate { get; init; }
        public byte Status { get; init; }
        public string StatusName { get; init; } = string.Empty;
        public string SourceKind { get; init; } = string.Empty;
        public bool IsAuto { get; init; }
        public int BranchId { get; init; }
        public string? BranchCode { get; init; }
        public string? BranchName { get; init; }
        public int? WarehouseId { get; init; }
        public string? WarehouseCode { get; init; }
        public string? WarehouseName { get; init; }
        public int? SupplierId { get; init; }
        public string? SupplierCode { get; init; }
        public string? SupplierName { get; init; }
        public int? ContainerId { get; init; }
        public string? ContainerRef { get; init; }
        public string? ContainerNo { get; init; }
        public int? PurchaseOrderId { get; init; }
        public string? PurchaseOrderNumber { get; init; }
        public int? PurchaseInvoiceId { get; init; }
        public string? PurchaseInvoiceNumber { get; init; }
        public int? MovementId { get; init; }
        public string? MovementNo { get; init; }
        public string? SupplierReference { get; init; }
        public int LineCount { get; init; }
        public int ExpectedBase { get; init; }
        public int ReceivedBase { get; init; }
        public int ShortBase { get; init; }
        public int InvoicedBase { get; init; }
        public decimal ValueBase { get; init; }
        public bool IsValueEstimate { get; init; }
        public DateTime? PostedAtUtc { get; init; }
        public string? PostedByName { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public string? CreatedByName { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public byte[] RowVersion { get; init; } = [];
        public int TotalCount { get; init; }

        public GoodsReceiptListItemDto ToDto() => new()
        {
            Id = Id,
            DocumentNumber = DocumentNumber,
            DocumentDate = DocumentDate,
            Status = Status,
            StatusName = StatusName.Length > 0 ? StatusName : GoodsReceiptStatus.Name(Status),
            SourceKind = SourceKind,
            IsAuto = IsAuto,
            BranchId = BranchId,
            BranchCode = BranchCode,
            BranchName = BranchName,
            WarehouseId = WarehouseId,
            WarehouseCode = WarehouseCode,
            WarehouseName = WarehouseName,
            SupplierId = SupplierId,
            SupplierCode = SupplierCode,
            SupplierName = SupplierName,
            ContainerId = ContainerId,
            ContainerRef = ContainerRef,
            ContainerNo = ContainerNo,
            PurchaseOrderId = PurchaseOrderId,
            PurchaseOrderNumber = PurchaseOrderNumber,
            PurchaseInvoiceId = PurchaseInvoiceId,
            PurchaseInvoiceNumber = PurchaseInvoiceNumber,
            MovementId = MovementId,
            MovementNo = MovementNo,
            SupplierReference = SupplierReference,
            LineCount = LineCount,
            ExpectedBase = ExpectedBase,
            ReceivedBase = ReceivedBase,
            ShortBase = ShortBase,
            InvoicedBase = InvoicedBase,
            ValueBase = ValueBase,
            IsValueEstimate = IsValueEstimate,
            PostedAtUtc = PostedAtUtc,
            PostedByName = PostedByName,
            CreatedAtUtc = CreatedAtUtc,
            CreatedByName = CreatedByName,
            UpdatedAtUtc = UpdatedAtUtc,
            RowVersion = RowVersion,
        };
    }

    public async Task<(IReadOnlyList<GoodsReceiptListItemDto> Items, int TotalCount, GoodsReceiptListTotalsDto Totals)> SearchAsync(
        GoodsReceiptQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
            Status = GoodsReceiptStatus.ToCode(query.Status),
            SourceKind = GoodsReceiptSourceKinds.Normalize(query.SourceKind),
            query.BranchId,
            query.SupplierId,
            query.WarehouseId,
            DateFrom = query.DateFrom?.ToDateTime(TimeOnly.MinValue),
            DateTo = query.DateTo?.ToDateTime(TimeOnly.MinValue),
            query.ContainerId,
            query.PurchaseOrderId,
            query.InvoiceId,
            query.MovementId,
            query.IsAuto,
            query.WithDifferences,
            query.ReceivedNotInvoiced,
            query.DeliveredNotReceived,
            query.NotReceived,
            SortColumn = SortColumns.FirstOrDefault(c => string.Equals(c, query.SortBy, StringComparison.OrdinalIgnoreCase)) ?? "DocumentDate",
            SortDirection = string.Equals(query.SortDir, "asc", StringComparison.OrdinalIgnoreCase) ? "ASC" : "DESC",
            PageNumber = query.Page,
            query.PageSize,
        };

        await using var connection = _connectionFactory.Create();
        try
        {
            using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
                "purchase.usp_GoodsReceipt_Search", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var rows = (await multi.ReadAsync<ListRow>()).AsList();
            var totals = await multi.ReadSingleOrDefaultAsync<GoodsReceiptListTotalsDto>() ?? new GoodsReceiptListTotalsDto();
            return (rows.Select(r => r.ToDto()).ToList(), rows.Count > 0 ? rows[0].TotalCount : 0, totals);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<GoodsReceiptWaitingDto> WaitingCountAsync(int userId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<GoodsReceiptWaitingDto>(new CommandDefinition(
                   "purchase.usp_GoodsReceipt_WaitingCount", new { UserId = userId },
                   commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))
               ?? new GoodsReceiptWaitingDto();
    }

    public async Task<GoodsReceiptSwitchDto> SwitchAsync(CancellationToken cancellationToken = default)
    {
        // The one marker row script 65 writes when it switches; none before it ran.
        const string sql = "SELECT SwitchedAtUtc = (SELECT s.SwitchedAtUtc FROM purchase.GoodsReceiptSwitch s WHERE s.Id = 1);";

        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<GoodsReceiptSwitchDto>(new CommandDefinition(
                   sql, cancellationToken: cancellationToken))
               ?? new GoodsReceiptSwitchDto();
    }

    public async Task<GoodsReceiptDto?> GetAsync(int id, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();

        // The six result sets in one round trip: the header's totals, the lines' costs and the matches are from the
        // same moment - a posting between two reads would otherwise not add up.
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "purchase.usp_GoodsReceipt_Get", new { Id = id },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var header = await multi.ReadSingleOrDefaultAsync<GoodsReceiptDto>();
        if (header is null)
        {
            return null;
        }

        var lines = (await multi.ReadAsync<GoodsReceiptLineDto>()).AsList();
        var matches = (await multi.ReadAsync<GoodsReceiptMatchDto>()).AsList();
        var costChanges = (await multi.ReadAsync<GoodsReceiptCostChangeDto>()).AsList();
        var files = (await multi.ReadAsync<DocumentFileDto>()).AsList();
        var audit = (await multi.ReadAsync<GoodsReceiptAuditDto>()).AsList();

        return header with
        {
            StatusName = header.StatusName.Length > 0 ? header.StatusName : GoodsReceiptStatus.Name(header.Status),
            Lines = lines,
            Matches = matches,
            CostChanges = costChanges,
            Files = files,
            Audit = audit,
        };
    }

    public async Task<GoodsReceiptStub?> GetStubAsync(int id, CancellationToken cancellationToken = default)
    {
        const string sql = "SELECT Id, Status, DocumentNumber FROM purchase.GoodsReceipts WHERE Id = @Id;";

        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<GoodsReceiptStub>(new CommandDefinition(
            sql, new { Id = id }, cancellationToken: cancellationToken));
    }

    /* ── writing ──────────────────────────────────────────────────────────────────────────────── */

    public async Task<int> SaveAsync(
        int? id, GoodsReceiptSaveRequest request, IReadOnlyList<GoodsReceiptSaveLineRequest> lines, int userId,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@SourceKind", GoodsReceiptSourceKinds.Normalize(request.SourceKind) ?? Trimmed(request.SourceKind), DbType.String, size: 10);
        parameters.Add("@DocumentDate", request.DocumentDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@BranchId", request.BranchId, DbType.Int32);
        parameters.Add("@WarehouseId", request.WarehouseId, DbType.Int32);
        parameters.Add("@SupplierId", request.SupplierId, DbType.Int32);
        parameters.Add("@ContainerId", request.ContainerId, DbType.Int32);
        parameters.Add("@PurchaseOrderId", request.PurchaseOrderId, DbType.Int32);
        parameters.Add("@PurchaseInvoiceId", request.PurchaseInvoiceId, DbType.Int32);
        parameters.Add("@SupplierReference", Trimmed(request.SupplierReference), DbType.String, size: 100);
        parameters.Add("@Notes", Trimmed(request.Notes), DbType.String, size: 1000);
        parameters.Add("@Lines", ToLineTable(lines).AsTableValuedParameter(LineTypeName));
        parameters.Add("@RowVersion", ToRowVersion(request.RowVersion), DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await ExecuteAsync("purchase.usp_GoodsReceipt_Save", parameters, cancellationToken);
        return parameters.Get<int>("@NewId");
    }

    public Task DeleteAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_GoodsReceipt_Delete",
            new { Id = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    /// <summary>
    /// The procedure answers the number as its own result set; it is read back from the row instead, so a result set
    /// a called procedure might add one day can never be taken for it.
    /// </summary>
    public async Task<string?> PostAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
    {
        await ExecuteAsync("purchase.usp_GoodsReceipt_Post",
            new { Id = id, RowVersion = rowVersion, UserId = userId }, cancellationToken);

        return (await GetStubAsync(id, cancellationToken))?.DocumentNumber;
    }

    public Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_GoodsReceipt_Cancel",
            new { Id = id, Reason = reason, RowVersion = rowVersion, UserId = userId }, cancellationToken);

    public async Task<int> CreateFromOrderAsync(
        int purchaseOrderId, IReadOnlyList<GoodsReceiptSaveLineRequest> lines, DateOnly? documentDate,
        string? supplierReference, int? warehouseId, string? notes, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@PurchaseOrderId", purchaseOrderId, DbType.Int32);
        parameters.Add("@Lines", ToLineTable(lines).AsTableValuedParameter(LineTypeName));
        parameters.Add("@DocumentDate", documentDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@SupplierReference", Trimmed(supplierReference), DbType.String, size: 100);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        parameters.Add("@WarehouseId", warehouseId, DbType.Int32);
        parameters.Add("@Notes", Trimmed(notes), DbType.String, size: 1000);

        await ExecuteAsync("purchase.usp_GoodsReceipt_CreateFromOrder", parameters, cancellationToken);
        return parameters.Get<int>("@NewId");
    }

    public async Task<int> CreateFromInvoiceAsync(
        int invoiceId, IReadOnlyList<GoodsReceiptSaveLineRequest> lines, DateOnly? documentDate,
        string? supplierReference, int? warehouseId, string? notes, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@InvoiceId", invoiceId, DbType.Int32);
        parameters.Add("@Lines", ToLineTable(lines).AsTableValuedParameter(LineTypeName));
        parameters.Add("@DocumentDate", documentDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@SupplierReference", Trimmed(supplierReference), DbType.String, size: 100);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        parameters.Add("@WarehouseId", warehouseId, DbType.Int32);
        parameters.Add("@Notes", Trimmed(notes), DbType.String, size: 1000);

        await ExecuteAsync("purchase.usp_GoodsReceipt_CreateFromInvoice", parameters, cancellationToken);
        return parameters.Get<int>("@NewId");
    }

    /// <summary>
    /// "Receive goods..." on a container: NOT SILENT, so a container that cannot be received is refused with its
    /// sentence (63010 / 63013 / 63009). The silent mode belongs to the Delivery hook (usp_GoodsReceipt_CreateForMovement).
    /// </summary>
    public async Task<int> CreateForContainerAsync(
        int containerId, IReadOnlyList<GoodsReceiptSaveLineRequest> lines, DateOnly? documentDate, int? warehouseId,
        int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@ContainerId", containerId, DbType.Int32);
        parameters.Add("@DocumentDate", documentDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@Silent", false, DbType.Boolean);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        parameters.Add("@SkipReason", dbType: DbType.String, size: 20, direction: ParameterDirection.Output);
        parameters.Add("@WarehouseId", warehouseId, DbType.Int32);
        parameters.Add("@Lines", ToLineTable(lines).AsTableValuedParameter(LineTypeName));

        await ExecuteAsync("purchase.usp_GoodsReceipt_CreateForContainer", parameters, cancellationToken);
        return parameters.Get<int?>("@NewId") ?? 0;
    }

    /* ── what can be received ─────────────────────────────────────────────────────────────────── */

    public async Task<IReadOnlyDictionary<int, LineItemUnit>> LineItemUnitsAsync(
        ReceivableLineTable table, IReadOnlyCollection<int> lineIds, CancellationToken cancellationToken = default)
    {
        if (lineIds.Count == 0)
        {
            return new Dictionary<int, LineItemUnit>();
        }

        var source = table == ReceivableLineTable.ContainerLine ? "logistics.ContainerLines" : "purchase.PurchaseDocumentLines";
        var sql = $"""
            SELECT LineId = l.Id, l.ItemId, BaseUnitId = bu.Id
            FROM {source} l
            OUTER APPLY (SELECT TOP (1) u.Id FROM inventory.ItemUnits u
                         WHERE u.ItemId = l.ItemId AND u.IsBaseUnit = 1 ORDER BY u.Id) bu
            WHERE l.Id IN @Ids;
            """;

        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<LineItemUnit>(new CommandDefinition(
            sql, new { Ids = lineIds.Distinct().ToArray() }, cancellationToken: cancellationToken));

        return rows.ToDictionary(r => r.LineId);
    }

    /// <summary>The item's base unit, applied to every line query below.</summary>
    private const string BaseUnitApply = """
        OUTER APPLY (SELECT TOP (1) u.Id, t.UnitTypeName
                     FROM inventory.ItemUnits u INNER JOIN masterdata.UnitTypes t ON t.Id = u.UnitTypeId
                     WHERE u.ItemId = i.Id AND u.IsBaseUnit = 1 ORDER BY u.Id) bu
        """;

    /// <summary>
    /// ONE ORDER, OR THE SUPPLIER'S ORDERS WITH SOMETHING TO RECEIVE ("+ New › From a purchase order..."): posted or
    /// closed, with pieces still to receive outside containers. An order with containers is "shipped in containers":
    /// its goods are received with them, so the dialog starts every line at 0.
    /// POSTED OR CLOSED ONLY, the one order too: this answer needs only purchase.goodsreceipts.create, and goods are
    /// received only against an approved order - a draft, waiting or cancelled order (lines and prices) is "not found".
    /// </summary>
    public async Task<ReceivableDto> OrderReceivableAsync(
        int? purchaseOrderId, int? supplierId, CancellationToken cancellationToken = default)
    {
        const string sql = $"""
            DECLARE @Orders TABLE (Id INT NOT NULL PRIMARY KEY, Seq INT NOT NULL, ShippedInContainers BIT NOT NULL);

            INSERT INTO @Orders (Id, Seq, ShippedInContainers)
            SELECT po.Id, ROW_NUMBER() OVER (ORDER BY po.DocumentDate, po.Id),
                   CAST(CASE WHEN EXISTS (SELECT 1
                                          FROM purchase.PurchaseDocumentLines l
                                          INNER JOIN logistics.ContainerLines cl ON cl.PoLineId = l.Id
                                          INNER JOIN logistics.Containers c      ON c.Id = cl.ContainerId AND c.Status <> 8
                                          WHERE l.DocumentId = po.Id) THEN 1 ELSE 0 END AS BIT)
            FROM purchase.PurchaseDocuments po
            INNER JOIN inventory.DocumentTypes dt ON dt.Id = po.DocumentTypeId AND dt.Code = N'PO'
            WHERE (@PurchaseOrderId IS NOT NULL AND po.Id = @PurchaseOrderId AND po.Status IN (2, 4))
               OR (@PurchaseOrderId IS NULL AND po.SupplierId = @SupplierId AND po.Status IN (2, 4)
                   AND EXISTS (SELECT 1 FROM purchase.fn_PoLine_Progress(po.Id) p WHERE p.ToReceiveBase > 0));

            SELECT SourceKind = N'Order', po.Id, po.DocumentNumber, po.DocumentDate, po.Status,
                   po.BranchId, b.BranchCode, b.BranchName, po.WarehouseId, w.WarehouseCode,
                   po.SupplierId, SupplierCode = sp.PartyCode, SupplierName = sp.PartyName,
                   o.ShippedInContainers, ReceivedAtPosting = CAST(0 AS BIT),
                   LineCount = s.Lines, ToReceiveBase = s.ToReceive, MaxOutsideBase = s.MaxOutside,
                   InContainersBase = s.InContainers, InDraftReceiptsBase = s.InDrafts
            FROM @Orders o
            INNER JOIN purchase.PurchaseDocuments po ON po.Id = o.Id
            INNER JOIN masterdata.Branches b         ON b.Id = po.BranchId
            INNER JOIN masterdata.Parties sp         ON sp.Id = po.SupplierId
            LEFT  JOIN masterdata.Warehouses w       ON w.Id = po.WarehouseId
            CROSS APPLY (SELECT Lines = COUNT(*), ToReceive = ISNULL(SUM(p.ToReceiveBase), 0),
                                MaxOutside = ISNULL(SUM(p.MaxOutsideBase), 0), InContainers = ISNULL(SUM(p.InContainersBase), 0),
                                InDrafts = ISNULL(SUM(p.InDraftReceiptsBase), 0)
                         FROM purchase.fn_PoLine_Progress(po.Id) p) s
            ORDER BY o.Seq;

            SELECT SourceKind = N'Order', DocumentId = po.Id, DocumentNumber = po.DocumentNumber, p.LineNumber,
                   PurchaseOrderId = po.Id, OrderNumber = po.DocumentNumber, p.PoLineId, PoLineNumber = p.LineNumber,
                   po.SupplierId, SupplierCode = sp.PartyCode, SupplierName = sp.PartyName,
                   p.ItemId, i.ItemCode, i.ItemName, p.ItemUnitId, ut.UnitTypeName, p.PackingFormula,
                   BaseItemUnitId = bu.Id, BaseUnitTypeName = bu.UnitTypeName,
                   p.WarehouseId, w.WarehouseCode, w.WarehouseName, pol.ExpiryDate,
                   p.OrderedBase, p.InvoicedBase, ReceivedBase = p.GoodsReceivedBase, ShortBase = p.GoodsShortBase,
                   p.InContainersBase, p.InDraftReceiptsBase, p.ToReceiveBase, p.MaxOutsideBase, p.OutstandingBase,
                   DefaultReceiveBase = CASE WHEN o.ShippedInContainers = 1 THEN 0 ELSE p.ToReceiveBase END,
                   UnitPriceBase = CAST(pol.LineTotal / NULLIF(po.ExchangeRate, 0) / NULLIF(pol.QuantityBase, 0) AS DECIMAL(18,6))
            FROM @Orders o
            INNER JOIN purchase.PurchaseDocuments po      ON po.Id = o.Id
            INNER JOIN masterdata.Parties sp              ON sp.Id = po.SupplierId
            CROSS APPLY purchase.fn_PoLine_Progress(po.Id) p
            INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = p.PoLineId
            INNER JOIN inventory.Items i                  ON i.Id = p.ItemId
            INNER JOIN inventory.ItemUnits iu             ON iu.Id = p.ItemUnitId
            INNER JOIN masterdata.UnitTypes ut            ON ut.Id = iu.UnitTypeId
            LEFT  JOIN masterdata.Warehouses w            ON w.Id = p.WarehouseId
            {BaseUnitApply}
            ORDER BY o.Seq, p.LineNumber;
            """;

        await using var connection = _connectionFactory.Create();
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            sql, new { PurchaseOrderId = purchaseOrderId, SupplierId = supplierId }, cancellationToken: cancellationToken));

        var documents = (await multi.ReadAsync<ReceivableDocumentDto>()).AsList();
        var lines = (await multi.ReadAsync<ReceivableLineDto>()).AsList();
        var first = documents.FirstOrDefault();

        return new ReceivableDto
        {
            Kind = purchaseOrderId is not null ? GoodsReceiptSourceKinds.Order : "Supplier",
            SupplierId = first?.SupplierId ?? supplierId,
            SupplierCode = first?.SupplierCode,
            SupplierName = first?.SupplierName,
            Documents = documents,
            Lines = lines,
        };
    }

    /// <summary>
    /// A SUPPLIER INVOICE'S LINES NOT LINKED TO A CONTAINER (the linked ones are received with their containers). An
    /// invoice "Shipped in containers" starts the dialog at 0; one posted before goods receipts without it has nothing
    /// to receive (its stock entered when it was posted).
    /// POSTED OR CLOSED ONLY: as the order's, this answer needs only purchase.goodsreceipts.create, and goods are received
    /// only against a posted invoice - a draft or cancelled one (lines and FOB) is "not found".
    /// </summary>
    public async Task<ReceivableDto?> InvoiceReceivableAsync(int invoiceId, CancellationToken cancellationToken = default)
    {
        const string sql = $"""
            SELECT SourceKind = N'Invoice', d.Id, d.DocumentNumber, d.DocumentDate, d.Status,
                   d.BranchId, b.BranchCode, b.BranchName, d.WarehouseId, w.WarehouseCode,
                   d.SupplierId, SupplierCode = sp.PartyCode, SupplierName = sp.PartyName,
                   ShippedInContainers = CAST(CASE WHEN d.ReceiptMode = 2 THEN 1 ELSE 0 END AS BIT),
                   ReceivedAtPosting = CAST(CASE WHEN d.UsesGoodsReceipts = 0 AND d.ReceiptMode = 1 THEN 1 ELSE 0 END AS BIT),
                   LineCount = s.Lines, ToReceiveBase = s.ToReceive, MaxOutsideBase = 0,
                   InContainersBase = ISNULL(c.InContainers, 0), InDraftReceiptsBase = s.InDrafts
            FROM purchase.PurchaseDocuments d
            INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PINV'
            INNER JOIN masterdata.Branches b      ON b.Id = d.BranchId
            INNER JOIN masterdata.Parties sp      ON sp.Id = d.SupplierId
            LEFT  JOIN masterdata.Warehouses w    ON w.Id = d.WarehouseId
            CROSS APPLY (SELECT Lines = COUNT(*), ToReceive = ISNULL(SUM(t.ToReceiveBase), 0), InDrafts = ISNULL(SUM(t.InDraftReceiptsBase), 0)
                         FROM purchase.fn_InvoiceLine_ToReceive(d.Id) t) s
            OUTER APPLY (SELECT InContainers = SUM(x.QuantityBase)
                         FROM purchase.PurchaseDocumentLines x WHERE x.DocumentId = d.Id AND x.ContainerLineId IS NOT NULL) c
            WHERE d.Id = @InvoiceId AND d.Status IN (2, 4);

            SELECT SourceKind = N'Invoice', DocumentId = d.Id, DocumentNumber = d.DocumentNumber, t.LineNumber,
                   PurchaseOrderId = po.Id, OrderNumber = po.DocumentNumber, t.PoLineId, PoLineNumber = pol.LineNumber,
                   InvoiceId = d.Id, InvoiceNumber = d.DocumentNumber, t.InvoiceLineId,
                   d.SupplierId, SupplierCode = sp.PartyCode, SupplierName = sp.PartyName,
                   t.ItemId, i.ItemCode, i.ItemName, t.ItemUnitId, ut.UnitTypeName, t.PackingFormula,
                   BaseItemUnitId = bu.Id, BaseUnitTypeName = bu.UnitTypeName,
                   t.WarehouseId, w.WarehouseCode, w.WarehouseName, ExpiryDate = COALESCE(t.ExpiryDate, pol.ExpiryDate),
                   OrderedBase = pol.QuantityBase, t.InvoicedBase, t.ReceivedBase, ShortBase = 0, InContainersBase = 0,
                   t.InDraftReceiptsBase, t.ToReceiveBase, t.ReturnedBase,
                   DefaultReceiveBase = CASE WHEN d.ReceiptMode = 2 THEN 0 ELSE t.ToReceiveBase END,
                   UnitPriceBase = CAST(COALESCE(pil.FobCostBase, pil.LineTotal / NULLIF(d.ExchangeRate, 0) / NULLIF(pil.QuantityBase, 0)) AS DECIMAL(18,6))
            FROM purchase.fn_InvoiceLine_ToReceive(@InvoiceId) t
            INNER JOIN purchase.PurchaseDocuments d       ON d.Id = t.InvoiceId
            INNER JOIN purchase.PurchaseDocumentLines pil ON pil.Id = t.InvoiceLineId
            INNER JOIN masterdata.Parties sp              ON sp.Id = d.SupplierId
            LEFT  JOIN purchase.PurchaseDocumentLines pol ON pol.Id = t.PoLineId
            LEFT  JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId
            INNER JOIN inventory.Items i                  ON i.Id = t.ItemId
            INNER JOIN inventory.ItemUnits iu             ON iu.Id = t.ItemUnitId
            INNER JOIN masterdata.UnitTypes ut            ON ut.Id = iu.UnitTypeId
            LEFT  JOIN masterdata.Warehouses w            ON w.Id = t.WarehouseId
            {BaseUnitApply}
            WHERE d.Status IN (2, 4)
            ORDER BY t.LineNumber;
            """;

        await using var connection = _connectionFactory.Create();
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            sql, new { InvoiceId = invoiceId }, cancellationToken: cancellationToken));

        var document = await multi.ReadSingleOrDefaultAsync<ReceivableDocumentDto>();
        var lines = (await multi.ReadAsync<ReceivableLineDto>()).AsList();
        if (document is null)
        {
            return null;
        }

        return new ReceivableDto
        {
            Kind = GoodsReceiptSourceKinds.Invoice,
            SupplierId = document.SupplierId,
            SupplierCode = document.SupplierCode,
            SupplierName = document.SupplierName,
            Documents = [document],
            Lines = lines,
        };
    }

    /// <summary>
    /// A container as "From a container..." and its "Receive goods..." see it. Receivable = status 2–5 (Confirmed to
    /// Cleared) and no draft or posted receipt (rule 6) - the eligibility of usp_GoodsReceipt_CreateForContainer.
    /// </summary>
    private const string ContainerSelect = """
        SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, c.Status, c.BranchId, b.BranchCode, b.BranchName,
               c.WarehouseId, w.WarehouseCode, w.WarehouseName,
               -- active, of the container's branch and at the bottom of the tree (script 72): what CreateForContainer takes
               WarehouseInBranch = CAST(CASE WHEN w.Id IS NULL THEN NULL
                                             WHEN w.IsActive = 1 AND w.BranchId = c.BranchId
                                                  AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1 THEN 1 ELSE 0 END AS BIT),
               SupplierId = CASE WHEN s.Suppliers = 1 THEN s.SupplierId END,
               SupplierName = CASE WHEN s.Suppliers = 1 THEN sp.PartyName WHEN s.Suppliers > 1 THEN N'Several suppliers' END,
               OrderNumbers = (SELECT STRING_AGG(x.DocumentNumber, N', ') WITHIN GROUP (ORDER BY x.DocumentNumber)
                               FROM (SELECT DISTINCT xo.DocumentNumber
                                     FROM logistics.ContainerLines xl
                                     INNER JOIN purchase.PurchaseDocumentLines xpl ON xpl.Id = xl.PoLineId
                                     INNER JOIN purchase.PurchaseDocuments xo      ON xo.Id = xpl.DocumentId
                                     WHERE xl.ContainerId = c.Id AND xo.DocumentNumber IS NOT NULL) x),
               LineCount = s.Lines, LoadedBase = s.Loaded,
               rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus, rb.ReceivedBy,
               DeliveryMovementNo = ld.MovementNo, DeliveredDate = ld.EndDate, DeliveryPlaceName = ld.PlaceName,
               MovementInProgressNo = mp.MovementNo,
               CanReceive = CAST(CASE WHEN c.Status BETWEEN 2 AND 5 AND rb.GoodsReceiptId IS NULL THEN 1 ELSE 0 END AS BIT)
        FROM logistics.Containers c
        INNER JOIN masterdata.Branches b   ON b.Id = c.BranchId
        LEFT  JOIN masterdata.Warehouses w ON w.Id = c.WarehouseId
        CROSS APPLY (SELECT Lines = COUNT(*), Loaded = ISNULL(SUM(cl.QuantityBase), 0),
                            Suppliers = COUNT(DISTINCT po.SupplierId), SupplierId = MIN(po.SupplierId)
                     FROM logistics.ContainerLines cl
                     LEFT JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
                     LEFT JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId
                     WHERE cl.ContainerId = c.Id) s
        LEFT  JOIN masterdata.Parties sp ON sp.Id = s.SupplierId AND s.Suppliers = 1
        CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
        OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) ld
        OUTER APPLY (SELECT TOP (1) m.MovementNo
                     FROM logistics.MovementContainers mc
                     INNER JOIN logistics.Movements m ON m.Id = mc.MovementId AND m.Status = 2
                     WHERE mc.ContainerId = c.Id
                     ORDER BY m.Id DESC) mp
        """;

    public async Task<ReceivableDto?> ContainerReceivableAsync(int containerId, CancellationToken cancellationToken = default)
    {
        const string sql = $"""
            {ContainerSelect}
            WHERE c.Id = @ContainerId;

            SELECT SourceKind = N'Container', DocumentId = c.Id, DocumentNumber = c.ContainerRef, cl.LineNumber,
                   PurchaseOrderId = po.Id, OrderNumber = po.DocumentNumber, cl.PoLineId, PoLineNumber = pol.LineNumber,
                   ContainerId = c.Id, ContainerLineId = cl.Id,
                   po.SupplierId, SupplierCode = sp.PartyCode, SupplierName = sp.PartyName,
                   cl.ItemId, i.ItemCode, i.ItemName, cl.ItemUnitId, ut.UnitTypeName, cl.PackingFormula,
                   BaseItemUnitId = bu.Id, BaseUnitTypeName = bu.UnitTypeName,
                   c.WarehouseId, w.WarehouseCode, w.WarehouseName, pol.ExpiryDate,
                   OrderedBase = pol.QuantityBase, ReceivedBase = ISNULL(cl.ReceivedQuantityBase, 0), ShortBase = 0, InContainersBase = 0,
                   InDraftReceiptsBase = ISNULL((SELECT SUM(gl.QuantityBase)
                                                 FROM purchase.GoodsReceiptLines gl
                                                 INNER JOIN purchase.GoodsReceipts g ON g.Id = gl.GoodsReceiptId AND g.Status = 1
                                                 WHERE gl.ContainerLineId = cl.Id), 0),
                   ToReceiveBase = CASE WHEN e.Eligible = 1 THEN cl.QuantityBase ELSE 0 END,
                   LoadedBase = cl.QuantityBase,
                   DefaultReceiveBase = CASE WHEN e.Eligible = 1 THEN cl.QuantityBase ELSE 0 END,
                   UnitPriceBase = CAST(pol.LineTotal / NULLIF(po.ExchangeRate, 0) / NULLIF(pol.QuantityBase, 0) AS DECIMAL(18,6))
            FROM logistics.Containers c
            INNER JOIN logistics.ContainerLines cl        ON cl.ContainerId = c.Id
            LEFT  JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
            LEFT  JOIN purchase.PurchaseDocuments po      ON po.Id = pol.DocumentId
            LEFT  JOIN masterdata.Parties sp              ON sp.Id = po.SupplierId
            INNER JOIN inventory.Items i                  ON i.Id = cl.ItemId
            INNER JOIN inventory.ItemUnits iu             ON iu.Id = cl.ItemUnitId
            INNER JOIN masterdata.UnitTypes ut            ON ut.Id = iu.UnitTypeId
            LEFT  JOIN masterdata.Warehouses w            ON w.Id = c.WarehouseId
            CROSS APPLY (SELECT Eligible = CASE WHEN c.Status BETWEEN 2 AND 5
                                                     AND NOT EXISTS (SELECT 1 FROM purchase.GoodsReceipts g
                                                                     WHERE g.ContainerId = c.Id AND g.Status < 3)
                                                THEN 1 ELSE 0 END) e
            {BaseUnitApply}
            WHERE c.Id = @ContainerId
            ORDER BY cl.LineNumber;
            """;

        await using var connection = _connectionFactory.Create();
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            sql, new { ContainerId = containerId }, cancellationToken: cancellationToken));

        var container = await multi.ReadSingleOrDefaultAsync<ReceivableContainerDto>();
        var lines = (await multi.ReadAsync<ReceivableLineDto>()).AsList();
        if (container is null)
        {
            return null;
        }

        return new ReceivableDto
        {
            Kind = GoodsReceiptSourceKinds.Container,
            SupplierId = container.SupplierId,
            SupplierName = container.SupplierName,
            Container = container,
            Lines = lines,
        };
    }

    public async Task<IReadOnlyList<ReceivableContainerDto>> ReceivableContainersAsync(
        ReceivableContainersQuery query, CancellationToken cancellationToken = default)
    {
        // At most 200, the delivered ones first (they are at the warehouse), then by reference.
        const string sql = $"""
            SELECT TOP (200) q.*
            FROM (
            {ContainerSelect}
            WHERE c.Status BETWEEN 2 AND 5 AND rb.GoodsReceiptId IS NULL
              AND (@BranchId IS NULL OR c.BranchId = @BranchId)
              AND (@SupplierId IS NULL
                   OR EXISTS (SELECT 1 FROM logistics.ContainerLines fl
                              INNER JOIN purchase.PurchaseDocumentLines fpl ON fpl.Id = fl.PoLineId
                              INNER JOIN purchase.PurchaseDocuments fo      ON fo.Id = fpl.DocumentId
                              WHERE fl.ContainerId = c.Id AND fo.SupplierId = @SupplierId))
              AND (@DeliveredOnly = 0 OR ld.MovementId IS NOT NULL)
              AND (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
                   OR EXISTS (SELECT 1 FROM logistics.ContainerLines sl
                              INNER JOIN purchase.PurchaseDocumentLines spl ON spl.Id = sl.PoLineId
                              INNER JOIN purchase.PurchaseDocuments so      ON so.Id = spl.DocumentId
                              WHERE sl.ContainerId = c.Id AND so.DocumentNumber LIKE N'%' + @Search + N'%'))
            ) q
            ORDER BY CASE WHEN q.DeliveredDate IS NULL THEN 1 ELSE 0 END, q.DeliveredDate DESC, q.ContainerRef;
            """;

        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<ReceivableContainerDto>(new CommandDefinition(
            sql,
            new
            {
                Search = string.IsNullOrWhiteSpace(query.Search) ? null : query.Search.Trim(),
                query.BranchId,
                query.SupplierId,
                query.DeliveredOnly,
            },
            cancellationToken: cancellationToken));

        return rows.AsList();
    }

    /* ── files ────────────────────────────────────────────────────────────────────────────────── */

    public async Task<int> AddFileAsync(
        int goodsReceiptId, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@GoodsReceiptId", goodsReceiptId, DbType.Int32);
        parameters.Add("@FileName", fileName, DbType.String, size: 255);
        parameters.Add("@ContentType", contentType, DbType.String, size: 100);
        parameters.Add("@SizeBytes", content.Length, DbType.Int32);
        parameters.Add("@Content", content, DbType.Binary, size: -1);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        parameters.Add("@AttachmentTypeId", fields.AttachmentTypeId, DbType.Int32);
        parameters.Add("@DocumentDate", fields.DocumentDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@Note", fields.Note, DbType.String, size: 500);

        await ExecuteAsync("purchase.usp_GoodsReceipt_File_Add", parameters, cancellationToken);
        return parameters.Get<int>("@NewId");
    }

    public async Task<IReadOnlyList<DocumentFileDto>> ListFilesAsync(
        int goodsReceiptId, int? attachmentTypeId = null, int? fileId = null, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<DocumentFileDto>(new CommandDefinition(
            "purchase.usp_GoodsReceipt_File_List",
            new { GoodsReceiptId = goodsReceiptId, AttachmentTypeId = attachmentTypeId, FileId = fileId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return rows.AsList();
    }

    public async Task<DocumentFileDto?> UpdateFileAsync(
        int fileId, DocumentFileEdit edit, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", fileId, DbType.Int32);
        parameters.Add("@AttachmentTypeId", edit.Fields.AttachmentTypeId, DbType.Int32);
        parameters.Add("@DocumentDate", edit.Fields.DocumentDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        parameters.Add("@Note", edit.Fields.Note, DbType.String, size: 500);
        parameters.Add("@FileName", edit.FileName, DbType.String, size: 255);
        parameters.Add("@ContentType", edit.ContentType, DbType.String, size: 100);
        parameters.Add("@SizeBytes", edit.Content?.Length, DbType.Int32);
        parameters.Add("@Content", edit.Content, DbType.Binary, size: -1);
        parameters.Add("@UserId", userId, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        try
        {
            return await connection.QuerySingleOrDefaultAsync<DocumentFileDto>(new CommandDefinition(
                "purchase.usp_GoodsReceipt_File_Update", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<GoodsReceiptFileContent?> GetFileAsync(int fileId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<GoodsReceiptFileContent>(new CommandDefinition(
            "purchase.usp_GoodsReceipt_File_Get", new { Id = fileId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    public Task DeleteFileAsync(int fileId, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("purchase.usp_GoodsReceipt_File_Delete", new { Id = fileId, UserId = userId }, cancellationToken);

    /* ── plumbing ─────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// One procedure call, run again if SQL Server made it the deadlock victim: posting a receipt locks the matcher,
    /// the receipt, its container and its order lines, and a reader of those arriving in between can be killed. The
    /// procedures are whole transactions, so the retry is clean.
    /// </summary>
    private async Task ExecuteAsync(string procedure, object parameters, CancellationToken cancellationToken)
    {
        try
        {
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.ExecuteAsync(new CommandDefinition(
                    procedure, parameters, commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            }, cancellationToken);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>
    /// The lines as a <see cref="DataTable"/> shaped like purchase.tvp_GoodsReceiptLine.
    ///
    /// COLUMN ORDER IS THE TYPE'S ORDER AND IS LOAD-BEARING - a table-valued parameter is sent positionally. Types are
    /// declared, not inferred: an all-null column infers as string and the server refuses the batch. Numbered 1..n in
    /// the order given (LineNumber is the type's key), whatever the caller sent.
    /// </summary>
    private static DataTable ToLineTable(IReadOnlyList<GoodsReceiptSaveLineRequest> lines)
    {
        var table = new DataTable();
        table.Columns.Add("LineNumber", typeof(int));
        table.Columns.Add("ItemId", typeof(int));
        table.Columns.Add("ItemUnitId", typeof(int));
        table.Columns.Add("Quantity", typeof(int));
        table.Columns.Add("WarehouseId", typeof(int));
        table.Columns.Add("PoLineId", typeof(int));
        table.Columns.Add("InvoiceLineId", typeof(int));
        table.Columns.Add("ContainerLineId", typeof(int));
        table.Columns.Add("ExpectedQuantityBase", typeof(int));
        table.Columns.Add("VarianceReasonCode", typeof(string));
        table.Columns.Add("VarianceReason", typeof(string));
        table.Columns.Add("CloseShort", typeof(bool));
        table.Columns.Add("ManualUnitCostBase", typeof(decimal));
        table.Columns.Add("ExpiryDate", typeof(DateTime));
        table.Columns.Add("Notes", typeof(string));

        var lineNumber = 1;
        foreach (var line in lines)
        {
            table.Rows.Add(
                lineNumber++,
                line.ItemId,
                line.ItemUnitId,
                line.Quantity,
                (object?)line.WarehouseId ?? DBNull.Value,
                (object?)line.PoLineId ?? DBNull.Value,
                (object?)line.InvoiceLineId ?? DBNull.Value,
                (object?)line.ContainerLineId ?? DBNull.Value,
                (object?)line.ExpectedQuantityBase ?? DBNull.Value,
                (object?)GoodsReceiptReasonCodes.Normalize(line.VarianceReasonCode) ?? DBNull.Value,
                (object?)Trimmed(line.VarianceReason) ?? DBNull.Value,
                line.CloseShort,
                (object?)line.ManualUnitCostBase ?? DBNull.Value,
                line.ExpiryDate is { } expiry ? expiry.ToDateTime(TimeOnly.MinValue) : DBNull.Value,
                (object?)Trimmed(line.Notes) ?? DBNull.Value);
        }

        return table;
    }

    private static string? Trimmed(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

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
