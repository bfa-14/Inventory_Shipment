using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Inventory.Transfers;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

/// <summary>
/// Transfer orders over script 90's procedures. Nothing is decided here: every rule, refusal and figure is the
/// procedures' (the order's state in inventory.fn_TransferOrder_State, the refusals in fn_TransferOrder_Blocks, where
/// From and To stand in fn_TransferPosition). This class shapes the table types, reads the result sets into the JSON
/// the pages draw, and turns a business THROW into a <see cref="Exceptions.BusinessRuleException"/>.
///
/// EVERY WRITE IS ONE TRANSACTION in its procedure, so a deadlock victim is run again (<see cref="SqlRetry"/>): a dispatch
/// locks the order, the source's dispatch lock and the ledger, and a reader of the order arriving in between can be
/// killed. The postings (dispatch, receipt, dispatch and receive) also get the batch command timeout.
/// </summary>
public sealed class TransferOrderRepository : ITransferOrderRepository
{
    /* Matched by TYPE NAME on the server. FROZEN in script 90 (2.3.5): a later change takes a new type. */
    private const string OrderLineTypeName = "inventory.tvp_TransferOrderLine";
    private const string DispatchLineTypeName = "inventory.tvp_TransferDispatchLine";
    private const string ReceiptLineTypeName = "inventory.tvp_TransferReceiptLine";
    private const string IdListTypeName = "logistics.tvp_IdList";

    /// <summary>The columns the search sorts by; anything else falls back to the order date.</summary>
    private static readonly string[] SortColumns =
    [
        "DocumentNumber", "DocumentDate", "FromWarehouse", "ToWarehouse", "Status", "OrderedBase", "OnTheWayBase",
        "ExpectedArrival", "CreatedAtUtc",
    ];

    private readonly ISqlConnectionFactory _connectionFactory;

    public TransferOrderRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /* ── the list ─────────────────────────────────────────────────────────────────────────────── */

    /// <summary>A list row as usp_TransferOrder_Search returns it: flat, the warehouses as columns.</summary>
    private sealed class ListRow
    {
        public int Id { get; init; }
        public string? DocumentNumber { get; init; }
        public DateTime DocumentDate { get; init; }
        public int BranchId { get; init; }
        public string? BranchCode { get; init; }
        public int FromWarehouseId { get; init; }
        public string? FromWarehouseCode { get; init; }
        public string? FromWarehouseName { get; init; }
        public string? FromBranchCode { get; init; }
        public int ToWarehouseId { get; init; }
        public string? ToWarehouseCode { get; init; }
        public string? ToWarehouseName { get; init; }
        public string? ToBranchCode { get; init; }
        public string? StatusCode { get; init; }
        public string? DisplayStatus { get; init; }
        public bool IsLate { get; init; }
        public int ItemCount { get; init; }
        public int OrderedBase { get; init; }
        public int DispatchedBase { get; init; }
        public int ReceivedBase { get; init; }
        public int OnTheWayBase { get; init; }
        public int ToDispatchBase { get; init; }
        public int NotSentBase { get; init; }
        public int LostBase { get; init; }
        public DateTime? ExpectedArrival { get; init; }
        public string? ReferenceNo { get; init; }
        public int? ReturnOfOrderId { get; init; }
        public string? ReturnOfNumber { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public string? CreatedByName { get; init; }
        public int TotalCount { get; init; }

        public TransferOrderListItemDto ToDto()
        {
            var status = StatusCode ?? TransferOrderStatuses.Draft;
            return new TransferOrderListItemDto
            {
                Id = Id,
                DocumentNumber = DocumentNumber,
                DocumentDate = DateOnly.FromDateTime(DocumentDate),
                BranchId = BranchId,
                BranchCode = BranchCode,
                From = new TransferWarehouseRefDto
                {
                    Id = FromWarehouseId, Code = FromWarehouseCode ?? string.Empty, Name = FromWarehouseName ?? string.Empty,
                    BranchCode = FromBranchCode,
                },
                To = new TransferWarehouseRefDto
                {
                    Id = ToWarehouseId, Code = ToWarehouseCode ?? string.Empty, Name = ToWarehouseName ?? string.Empty,
                    BranchCode = ToBranchCode,
                },
                Status = status,
                DisplayStatus = DisplayStatus ?? status,
                IsLate = IsLate,
                ItemCount = ItemCount,
                OrderedBase = OrderedBase,
                DispatchedBase = DispatchedBase,
                ReceivedBase = ReceivedBase,
                OnTheWayBase = OnTheWayBase,
                ToDispatchBase = ToDispatchBase,
                NotSentBase = NotSentBase,
                LostBase = LostBase,
                ExpectedArrival = ToDateOnly(ExpectedArrival),
                ReferenceNo = ReferenceNo,
                ReturnOfOrderId = ReturnOfOrderId,
                ReturnOfNumber = ReturnOfNumber,
                CreatedAtUtc = CreatedAtUtc,
                CreatedByName = CreatedByName,
            };
        }
    }

    public async Task<(IReadOnlyList<TransferOrderListItemDto> Items, int TotalCount, TransferOrderListTotalsDto Totals)> SearchAsync(
        TransferOrderQuery query, CancellationToken cancellationToken = default)
    {
        var parameters = new
        {
            Search = Trimmed(query.Search),
            Status = Trimmed(query.Status),
            query.BranchId,
            query.FromWarehouseId,
            query.ToWarehouseId,
            query.OnTheWayOnly,
            query.LateOnly,
            query.WaitingForApproval,
            DateFrom = ToDate(query.DateFrom),
            DateTo = ToDate(query.DateTo),
            query.ItemId,
            SortColumn = SortColumns.FirstOrDefault(c => string.Equals(c, query.SortColumn, StringComparison.OrdinalIgnoreCase)) ?? "DocumentDate",
            SortDirection = string.Equals(query.SortDirection, "asc", StringComparison.OrdinalIgnoreCase) ? "ASC" : "DESC",
            PageNumber = Math.Max(query.Page, 1),
            PageSize = Math.Clamp(query.PageSize, 1, 200),
        };

        await using var connection = _connectionFactory.Create();
        try
        {
            using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
                "inventory.usp_TransferOrder_Search", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            var rows = (await multi.ReadAsync<ListRow>()).AsList();
            var totals = await multi.ReadSingleOrDefaultAsync<TransferOrderListTotalsDto>() ?? new TransferOrderListTotalsDto();
            return (rows.Select(r => r.ToDto()).ToList(), rows.Count > 0 ? rows[0].TotalCount : 0, totals);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<int> WaitingCountAsync(int userId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<int?>(new CommandDefinition(
                   "inventory.usp_TransferOrder_WaitingCount", new { UserId = userId },
                   commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken))
               ?? 0;
    }

    public async Task<IReadOnlyList<TransferAvailabilityDto>> AvailabilityAsync(
        int fromWarehouseId, int toWarehouseId, IReadOnlyCollection<int> itemIds, int? excludeOrderId,
        CancellationToken cancellationToken = default)
    {
        if (itemIds.Count == 0)
        {
            return [];
        }

        var parameters = new DynamicParameters();
        parameters.Add("@FromWarehouseId", fromWarehouseId, DbType.Int32);
        parameters.Add("@ToWarehouseId", toWarehouseId, DbType.Int32);
        // A table, not "IN @Ids": one parameter per id would stop at SQL Server's 2,100.
        parameters.Add("@ItemIds", MovementRepository.ToIdTable(itemIds).AsTableValuedParameter(IdListTypeName));
        parameters.Add("@ExcludeOrderId", excludeOrderId, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<TransferAvailabilityDto>(new CommandDefinition(
                "inventory.usp_TransferOrder_Availability", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            return rows.AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /* ── one order ────────────────────────────────────────────────────────────────────────────── */

    /// <summary>Result set 1 of usp_TransferOrder_Get: the header, its stamps, its figures and every action's answer.</summary>
    private sealed class HeaderRow
    {
        public int Id { get; init; }
        public string? DocumentNumber { get; init; }
        public DateTime DocumentDate { get; init; }
        public int BranchId { get; init; }
        public string? BranchCode { get; init; }
        public int FromWarehouseId { get; init; }
        public string? FromWarehouseCode { get; init; }
        public string? FromWarehouseName { get; init; }
        public int? FromBranchId { get; init; }
        public string? FromBranchCode { get; init; }
        public string? FromBranchName { get; init; }
        public int ToWarehouseId { get; init; }
        public string? ToWarehouseCode { get; init; }
        public string? ToWarehouseName { get; init; }
        public int? ToBranchId { get; init; }
        public string? ToBranchCode { get; init; }
        public string? ToBranchName { get; init; }
        public DateTime? ExpectedArrival { get; init; }
        public string? ReferenceNo { get; init; }
        public string? Notes { get; init; }
        public byte Status { get; init; }
        public string? StatusCode { get; init; }
        public int? ReturnOfOrderId { get; init; }
        public string? ReturnOfNumber { get; init; }
        public DateTime? ApprovalRequestedAtUtc { get; init; }
        public string? ApprovalRequestedByName { get; init; }
        public DateTime? ApprovedAtUtc { get; init; }
        public string? ApprovedByName { get; init; }
        public bool ApprovedDirectly { get; init; }
        public DateTime? RejectedAtUtc { get; init; }
        public string? RejectedByName { get; init; }
        public string? RejectReason { get; init; }
        public DateTime? ReleasedAtUtc { get; init; }
        public string? ReleasedByName { get; init; }
        public DateTime? NotSentAtUtc { get; init; }
        public string? NotSentByName { get; init; }
        public string? NotSentReason { get; init; }
        public DateTime? CancelledAtUtc { get; init; }
        public string? CancelledByName { get; init; }
        public string? CancelReason { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public string? CreatedByName { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public string? UpdatedByName { get; init; }
        public bool NeedsApproval { get; init; }
        public bool NumberOnPost { get; init; }
        public int OrderedBase { get; init; }
        public int DispatchedBase { get; init; }
        public int ReceivedBase { get; init; }
        public int LostBase { get; init; }
        public int NotSentBase { get; init; }
        public int ToDispatchBase { get; init; }
        public int OnTheWayBase { get; init; }
        public int ItemCount { get; init; }
        public int LateDispatches { get; init; }
        public bool IsLate { get; init; }
        public string? DisplayStatus { get; init; }
        public decimal? OnTheWayValueBase { get; init; }
        public bool CanEdit { get; init; }
        public string? EditBlockedReason { get; init; }
        public bool CanDelete { get; init; }
        public string? DeleteBlockedReason { get; init; }
        public bool CanRelease { get; init; }
        public string? ReleaseBlockedReason { get; init; }
        public bool CanSendForApproval { get; init; }
        public string? SendForApprovalBlockedReason { get; init; }
        public bool CanApprove { get; init; }
        public string? ApproveBlockedReason { get; init; }
        public bool CanReject { get; init; }
        public string? RejectBlockedReason { get; init; }
        public bool CanWithdraw { get; init; }
        public string? WithdrawBlockedReason { get; init; }
        public bool CanBackToDraft { get; init; }
        public string? BackToDraftBlockedReason { get; init; }
        public bool CanDispatch { get; init; }
        public string? DispatchBlockedReason { get; init; }
        public bool CanReceive { get; init; }
        public string? ReceiveBlockedReason { get; init; }
        public bool CanDispatchAndReceive { get; init; }
        public string? DispatchAndReceiveBlockedReason { get; init; }
        public bool CanNothingMoreSent { get; init; }
        public string? NothingMoreSentBlockedReason { get; init; }
        public bool CanCancel { get; init; }
        public string? CancelBlockedReason { get; init; }
        public bool CanCreateReturn { get; init; }
        public string? CreateReturnBlockedReason { get; init; }
        public bool CanUpdateDetails { get; init; }
        public string? UpdateDetailsBlockedReason { get; init; }
        public bool CanEditExpectedArrival { get; init; }
        public string? EditExpectedArrivalBlockedReason { get; init; }
        public byte[] RowVersion { get; init; } = [];
    }

    /// <summary>Result set 3: one dispatch or receipt, flat.</summary>
    private sealed class PostingRow
    {
        public int Id { get; init; }
        public string? Kind { get; init; }
        public string? DocumentTypeCode { get; init; }
        public string? DocumentNumber { get; init; }
        public DateTime PostingDate { get; init; }
        public DateTime? Eta { get; init; }
        public string? ReferenceNo { get; init; }
        public string? Notes { get; init; }
        public string? StatusCode { get; init; }
        public int? TransitWarehouseId { get; init; }
        public string? TransitWarehouseCode { get; init; }
        public string? TransitWarehouseName { get; init; }
        public string? BranchCode { get; init; }
        public int? PostedWithId { get; init; }
        public string? PostedWithNumber { get; init; }
        public int TotalQuantityBase { get; init; }
        public int TotalLostBase { get; init; }
        public int OnTheWayBase { get; init; }
        public bool IsLate { get; init; }
        public decimal? ValueBase { get; init; }
        public decimal? LostValueBase { get; init; }
        public DateTime PostedAtUtc { get; init; }
        public string? PostedByName { get; init; }
        public DateTime? ReverseDate { get; init; }
        public DateTime? ReversedAtUtc { get; init; }
        public string? ReversedByName { get; init; }
        public string? ReverseReason { get; init; }
        public bool CanReverse { get; init; }
        public string? ReverseBlockedReason { get; init; }
        public bool CanChangeEta { get; init; }
        public string? ChangeEtaBlockedReason { get; init; }
    }

    /// <summary>Result set 4: a posting's line, with the posting it belongs to.</summary>
    private sealed class PostingLineRow
    {
        public int Id { get; init; }
        public int PostingId { get; init; }
        public int LineNumber { get; init; }
        public int TransferOrderLineId { get; init; }
        public int OrderLineNumber { get; init; }
        public int ItemId { get; init; }
        public string? ItemCode { get; init; }
        public string? ItemName { get; init; }
        public int QuantityBase { get; init; }
        public int LostBase { get; init; }
        public string? LossReasonCode { get; init; }
        public string? LossNote { get; init; }
        public int SettledBase { get; init; }
        public int OnTheWayBase { get; init; }
        public int? DispatchLineId { get; init; }
        public string? DispatchNumber { get; init; }
        public decimal? UnitCostBase { get; init; }
        public decimal? LossUnitCostBase { get; init; }
    }

    /// <summary>Result set 6: a return of the order.</summary>
    private sealed class ReturnRow
    {
        public int Id { get; init; }
        public string? DocumentNumber { get; init; }
        public DateTime? DocumentDate { get; init; }
        public string? StatusCode { get; init; }
        public string? DisplayStatus { get; init; }
    }

    public async Task<TransferOrderDto?> GetAsync(int id, int userId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();

        // The six result sets in one round trip: the header's figures, the lines' counters and the postings' answers are
        // from the same moment - a posting between two reads would otherwise not add up.
        using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            "inventory.usp_TransferOrder_Get", new { Id = id, UserId = userId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        var header = await multi.ReadSingleOrDefaultAsync<HeaderRow>();
        var lines = (await multi.ReadAsync<TransferOrderLineDto>()).AsList();
        var postings = (await multi.ReadAsync<PostingRow>()).AsList();
        var postingLines = (await multi.ReadAsync<PostingLineRow>()).AsList();
        var audit = (await multi.ReadAsync<TransferOrderAuditDto>()).AsList();
        var returns = (await multi.ReadAsync<ReturnRow>()).AsList();
        if (header is null)
        {
            return null;
        }

        var linesByPosting = postingLines.GroupBy(l => l.PostingId).ToDictionary(g => g.Key, g => g.Select(ToDto).ToList());
        var status = header.StatusCode ?? TransferOrderStatuses.From(header.Status);

        return new TransferOrderDto
        {
            Id = header.Id,
            DocumentNumber = header.DocumentNumber,
            DocumentDate = DateOnly.FromDateTime(header.DocumentDate),
            BranchId = header.BranchId,
            BranchCode = header.BranchCode,
            From = new TransferWarehouseRefDto
            {
                Id = header.FromWarehouseId, Code = header.FromWarehouseCode ?? string.Empty, Name = header.FromWarehouseName ?? string.Empty,
                BranchId = header.FromBranchId, BranchCode = header.FromBranchCode, BranchName = header.FromBranchName,
            },
            To = new TransferWarehouseRefDto
            {
                Id = header.ToWarehouseId, Code = header.ToWarehouseCode ?? string.Empty, Name = header.ToWarehouseName ?? string.Empty,
                BranchId = header.ToBranchId, BranchCode = header.ToBranchCode, BranchName = header.ToBranchName,
            },
            ExpectedArrival = ToDateOnly(header.ExpectedArrival),
            ReferenceNo = header.ReferenceNo,
            Notes = header.Notes,
            Status = status,
            DisplayStatus = header.DisplayStatus ?? status,
            IsLate = header.IsLate,
            NeedsApproval = header.NeedsApproval,
            NumberOnPost = header.NumberOnPost,
            Totals = new TransferOrderFiguresDto
            {
                OrderedBase = header.OrderedBase,
                DispatchedBase = header.DispatchedBase,
                ReceivedBase = header.ReceivedBase,
                OnTheWayBase = header.OnTheWayBase,
                ToDispatchBase = header.ToDispatchBase,
                NotSentBase = header.NotSentBase,
                LostBase = header.LostBase,
                ItemCount = header.ItemCount,
                LateDispatches = header.LateDispatches,
            },
            OnTheWayValueBase = header.OnTheWayValueBase,
            Approval = new TransferApprovalDto
            {
                RequestedAtUtc = header.ApprovalRequestedAtUtc,
                RequestedByName = header.ApprovalRequestedByName,
                ApprovedAtUtc = header.ApprovedAtUtc,
                ApprovedByName = header.ApprovedByName,
                ApprovedDirectly = header.ApprovedDirectly,
                RejectedAtUtc = header.RejectedAtUtc,
                RejectedByName = header.RejectedByName,
                RejectReason = header.RejectReason,
            },
            Released = header.ReleasedAtUtc is { } releasedAt
                ? new TransferStampDto { AtUtc = releasedAt, ByName = header.ReleasedByName }
                : null,
            NotSent = header.NotSentAtUtc is { } notSentAt
                ? new TransferStampDto { AtUtc = notSentAt, ByName = header.NotSentByName, Reason = header.NotSentReason }
                : null,
            Cancelled = header.CancelledAtUtc is { } cancelledAt
                ? new TransferStampDto { AtUtc = cancelledAt, ByName = header.CancelledByName, Reason = header.CancelReason }
                : null,
            ReturnOf = header.ReturnOfOrderId is { } returnOfId
                ? new TransferOrderLinkDto { Id = returnOfId, DocumentNumber = header.ReturnOfNumber }
                : null,
            Returns = returns.Select(r => new TransferOrderLinkDto
            {
                Id = r.Id,
                DocumentNumber = r.DocumentNumber,
                DocumentDate = ToDateOnly(r.DocumentDate),
                Status = r.StatusCode,
                DisplayStatus = r.DisplayStatus ?? r.StatusCode,
            }).ToList(),
            Abilities = new TransferOrderAbilitiesDto
            {
                Edit = TransferAbilityDto.Of(header.CanEdit, header.EditBlockedReason),
                Delete = TransferAbilityDto.Of(header.CanDelete, header.DeleteBlockedReason),
                Release = TransferAbilityDto.Of(header.CanRelease, header.ReleaseBlockedReason),
                SendForApproval = TransferAbilityDto.Of(header.CanSendForApproval, header.SendForApprovalBlockedReason),
                Approve = TransferAbilityDto.Of(header.CanApprove, header.ApproveBlockedReason),
                Reject = TransferAbilityDto.Of(header.CanReject, header.RejectBlockedReason),
                Withdraw = TransferAbilityDto.Of(header.CanWithdraw, header.WithdrawBlockedReason),
                BackToDraft = TransferAbilityDto.Of(header.CanBackToDraft, header.BackToDraftBlockedReason),
                Dispatch = TransferAbilityDto.Of(header.CanDispatch, header.DispatchBlockedReason),
                Receive = TransferAbilityDto.Of(header.CanReceive, header.ReceiveBlockedReason),
                DispatchAndReceive = TransferAbilityDto.Of(header.CanDispatchAndReceive, header.DispatchAndReceiveBlockedReason),
                NothingMoreSent = TransferAbilityDto.Of(header.CanNothingMoreSent, header.NothingMoreSentBlockedReason),
                Cancel = TransferAbilityDto.Of(header.CanCancel, header.CancelBlockedReason),
                CreateReturn = TransferAbilityDto.Of(header.CanCreateReturn, header.CreateReturnBlockedReason),
                UpdateDetails = TransferAbilityDto.Of(header.CanUpdateDetails, header.UpdateDetailsBlockedReason),
                EditExpectedArrival = TransferAbilityDto.Of(header.CanEditExpectedArrival, header.EditExpectedArrivalBlockedReason),
            },
            Lines = lines,
            Postings = postings.Select(p => ToDto(p, linesByPosting.TryGetValue(p.Id, out var own) ? own : [])).ToList(),
            Audit = audit,
            CreatedAtUtc = header.CreatedAtUtc,
            CreatedByName = header.CreatedByName,
            UpdatedAtUtc = header.UpdatedAtUtc,
            UpdatedByName = header.UpdatedByName,
            RowVersion = Convert.ToBase64String(header.RowVersion),
        };
    }

    private static TransferPostingDto ToDto(PostingRow p, IReadOnlyList<TransferPostingLineDto> lines) => new()
    {
        Id = p.Id,
        Kind = p.Kind ?? TransferPostingKinds.Dispatch,
        DocumentTypeCode = p.DocumentTypeCode ?? (p.Kind == TransferPostingKinds.Receipt ? "TRR" : "TRD"),
        DocumentNumber = p.DocumentNumber ?? string.Empty,
        PostingDate = DateOnly.FromDateTime(p.PostingDate),
        Eta = ToDateOnly(p.Eta),
        ReferenceNo = p.ReferenceNo,
        Notes = p.Notes,
        Status = p.StatusCode ?? "Posted",
        TransitWarehouse = p.TransitWarehouseId is { } transitId
            ? new TransferTransitWarehouseDto { Id = transitId, Code = p.TransitWarehouseCode ?? string.Empty, Name = p.TransitWarehouseName ?? string.Empty }
            : null,
        BranchCode = p.BranchCode,
        PostedWithId = p.PostedWithId,
        PostedWithNumber = p.PostedWithNumber,
        TotalQuantityBase = p.TotalQuantityBase,
        TotalLostBase = p.TotalLostBase,
        OnTheWayBase = p.OnTheWayBase,
        IsLate = p.IsLate,
        ValueBase = p.ValueBase,
        // A dispatch writes nothing off: its lost value is "not applicable", not a measured 0 (a receipt's may be 0).
        LostValueBase = p.Kind == TransferPostingKinds.Receipt ? p.LostValueBase : null,
        PostedAtUtc = p.PostedAtUtc,
        PostedByName = p.PostedByName,
        // A posting is reversed once its reversal is stamped: the date, the moment, who and why.
        Reversed = p.ReversedAtUtc is { } reversedAt
            ? new TransferReversalDto
            {
                Date = DateOnly.FromDateTime(p.ReverseDate ?? reversedAt),
                AtUtc = reversedAt,
                ByName = p.ReversedByName,
                Reason = p.ReverseReason ?? string.Empty,
            }
            : null,
        CanReverse = p.CanReverse && string.IsNullOrEmpty(p.ReverseBlockedReason),
        ReverseBlockedReason = p.ReverseBlockedReason,
        CanChangeEta = p.CanChangeEta && string.IsNullOrEmpty(p.ChangeEtaBlockedReason),
        ChangeEtaBlockedReason = p.ChangeEtaBlockedReason,
        Lines = lines,
    };

    private static TransferPostingLineDto ToDto(PostingLineRow l) => new()
    {
        Id = l.Id,
        LineNumber = l.LineNumber,
        TransferOrderLineId = l.TransferOrderLineId,
        OrderLineNumber = l.OrderLineNumber,
        ItemId = l.ItemId,
        ItemCode = l.ItemCode ?? string.Empty,
        ItemName = l.ItemName ?? string.Empty,
        QuantityBase = l.QuantityBase,
        LostBase = l.LostBase,
        LossReasonCode = l.LossReasonCode,
        LossNote = l.LossNote,
        SettledBase = l.SettledBase,
        OnTheWayBase = l.OnTheWayBase,
        DispatchLineId = l.DispatchLineId,
        DispatchNumber = l.DispatchNumber,
        UnitCostBase = l.UnitCostBase,
        LossUnitCostBase = l.LossUnitCostBase,
    };

    public async Task<bool> ExistsAsync(int id, CancellationToken cancellationToken = default)
    {
        const string sql = "SELECT CAST(CASE WHEN EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id) THEN 1 ELSE 0 END AS BIT);";

        await using var connection = _connectionFactory.Create();
        return await connection.ExecuteScalarAsync<bool>(new CommandDefinition(sql, new { Id = id }, cancellationToken: cancellationToken));
    }

    public async Task<int?> PostingOrderIdAsync(int postingId, CancellationToken cancellationToken = default)
    {
        const string sql = "SELECT TransferOrderId FROM inventory.TransferPostings WHERE Id = @Id;";

        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<int?>(new CommandDefinition(
            sql, new { Id = postingId }, cancellationToken: cancellationToken));
    }

    /* ── the draft ────────────────────────────────────────────────────────────────────────────── */

    public async Task<int> SaveAsync(
        int? id, SaveTransferOrderRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@DocumentDate", ToDate(request.DocumentDate), DbType.Date);
        parameters.Add("@FromWarehouseId", request.FromWarehouseId, DbType.Int32);
        parameters.Add("@ToWarehouseId", request.ToWarehouseId, DbType.Int32);
        parameters.Add("@ExpectedArrival", ToDate(request.ExpectedArrival), DbType.Date);
        parameters.Add("@ReferenceNo", Trimmed(request.ReferenceNo), DbType.String, size: 100);
        parameters.Add("@Notes", Trimmed(request.Notes), DbType.String, size: 1000);
        parameters.Add("@Lines", ToOrderLineTable(request.Lines).AsTableValuedParameter(OrderLineTypeName));
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await ExecuteAsync("inventory.usp_TransferOrder_Save", parameters, cancellationToken);
        return parameters.Get<int?>("@NewId") ?? id ?? 0;
    }

    public Task UpdateDetailsAsync(
        int id, UpdateTransferDetailsRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@ExpectedArrival", ToDate(request.ExpectedArrival), DbType.Date);
        parameters.Add("@ReferenceNo", Trimmed(request.ReferenceNo), DbType.String, size: 100);
        parameters.Add("@Notes", Trimmed(request.Notes), DbType.String, size: 1000);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        return ExecuteAsync("inventory.usp_TransferOrder_UpdateDetails", parameters, cancellationToken);
    }

    public Task DeleteAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("inventory.usp_TransferOrder_Delete", OrderParameters(id, rowVersion, userId), cancellationToken);

    /* ── release and approval ─────────────────────────────────────────────────────────────────── */

    /// <summary>A warning row (Release's and Approve's result set 1).</summary>
    private sealed class MessageRow
    {
        public string? Message { get; init; }
    }

    public async Task<IReadOnlyList<string>> ReleaseAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = OrderParameters(id, rowVersion, userId);
        return await QueryMultipleAsync("inventory.usp_TransferOrder_Release", parameters, null, async multi =>
            Messages(await multi.ReadAsync<MessageRow>()), cancellationToken);
    }

    public async Task<IReadOnlyList<TransferApproverDto>> SendForApprovalAsync(
        int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = OrderParameters(id, rowVersion, userId);
        return await QueryMultipleAsync("inventory.usp_TransferOrder_SendForApproval", parameters, null, async multi =>
            (IReadOnlyList<TransferApproverDto>)(await multi.ReadAsync<TransferApproverDto>()).AsList(), cancellationToken);
    }

    public async Task<(IReadOnlyList<string> Warnings, TransferRequesterDto? Requester)> ApproveAsync(
        int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = OrderParameters(id, rowVersion, userId);
        return await QueryMultipleAsync("inventory.usp_TransferOrder_Approve", parameters, null, async multi =>
        {
            var warnings = Messages(await multi.ReadAsync<MessageRow>());
            // Result 2 has no row for a direct approval (Approve & release of a draft): nobody asked, nobody to tell.
            var requester = multi.IsConsumed ? null : await multi.ReadFirstOrDefaultAsync<TransferRequesterDto>();
            return (warnings, requester);
        }, cancellationToken);
    }

    public async Task<TransferRequesterDto?> RejectAsync(
        int id, byte[]? rowVersion, string? reason, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = ReasonParameters(id, rowVersion, reason, userId);
        return await QueryMultipleAsync("inventory.usp_TransferOrder_Reject", parameters, null, async multi =>
            await multi.ReadFirstOrDefaultAsync<TransferRequesterDto>(), cancellationToken);
    }

    public Task WithdrawAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("inventory.usp_TransferOrder_Withdraw", OrderParameters(id, rowVersion, userId), cancellationToken);

    public Task BackToDraftAsync(int id, byte[]? rowVersion, string? reason, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("inventory.usp_TransferOrder_BackToDraft", ReasonParameters(id, rowVersion, reason, userId), cancellationToken);

    /* ── the postings ─────────────────────────────────────────────────────────────────────────── */

    public async Task<TransferPostedRefDto> DispatchAsync(
        int id, DispatchTransferRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = DispatchParameters(id, request, rowVersion, userId, withEta: true);

        // The posting's id and number come back as OUTPUT parameters: a result set a called procedure might add one day
        // could never be taken for them.
        await ExecuteAsync("inventory.usp_TransferOrder_Dispatch", parameters, cancellationToken, batch: true);
        return new TransferPostedRefDto
        {
            Id = parameters.Get<int?>("@PostingId") ?? 0,
            Kind = TransferPostingKinds.Dispatch,
            DocumentNumber = parameters.Get<string?>("@DocumentNumber") ?? string.Empty,
        };
    }

    public async Task<TransferPostedRefDto> ReceiveAsync(
        int id, ReceiveTransferRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@Date", ToDate(request.Date), DbType.Date);
        parameters.Add("@ReferenceNo", Trimmed(request.ReferenceNo), DbType.String, size: 100);
        parameters.Add("@Notes", Trimmed(request.Notes), DbType.String, size: 1000);
        parameters.Add("@Lines", ToReceiptLineTable(request.Lines).AsTableValuedParameter(ReceiptLineTypeName));
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@PostingId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        parameters.Add("@DocumentNumber", dbType: DbType.String, size: 30, direction: ParameterDirection.Output);

        await ExecuteAsync("inventory.usp_TransferOrder_Receive", parameters, cancellationToken, batch: true);
        return new TransferPostedRefDto
        {
            Id = parameters.Get<int?>("@PostingId") ?? 0,
            Kind = TransferPostingKinds.Receipt,
            DocumentNumber = parameters.Get<string?>("@DocumentNumber") ?? string.Empty,
        };
    }

    /// <summary>The answer of "Dispatch and receive": both postings, the dispatch first.</summary>
    private sealed class DispatchAndReceiveRow
    {
        public int? DispatchPostingId { get; init; }
        public string? DispatchNumber { get; init; }
        public int? ReceiptPostingId { get; init; }
        public string? ReceiptNumber { get; init; }
    }

    public async Task<(TransferPostedRefDto Dispatch, TransferPostedRefDto Receipt)> DispatchAndReceiveAsync(
        int id, DispatchTransferRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default)
    {
        // ETA is not sent: the goods arrive on the dispatch date (the procedure ignores it).
        var parameters = DispatchParameters(id, request, rowVersion, userId, withEta: false);

        // The receipt's id and number are only in the procedure's answer; the dispatch's are OUTPUT parameters as well.
        // The answer is the LAST result set that carries them (the cores select nothing, but a future one might).
        var row = await QueryMultipleAsync("inventory.usp_TransferOrder_DispatchAndReceive", parameters,
            _connectionFactory.BatchCommandTimeout, async multi =>
            {
                DispatchAndReceiveRow? last = null;
                while (!multi.IsConsumed)
                {
                    last = await multi.ReadFirstOrDefaultAsync<DispatchAndReceiveRow>() ?? last;
                }

                return last;
            }, cancellationToken);

        var dispatchId = row?.DispatchPostingId ?? parameters.Get<int?>("@PostingId") ?? 0;
        var dispatchNumber = row?.DispatchNumber ?? parameters.Get<string?>("@DocumentNumber") ?? string.Empty;
        return (
            new TransferPostedRefDto { Id = dispatchId, Kind = TransferPostingKinds.Dispatch, DocumentNumber = dispatchNumber },
            new TransferPostedRefDto
            {
                Id = row?.ReceiptPostingId ?? 0,
                Kind = TransferPostingKinds.Receipt,
                DocumentNumber = row?.ReceiptNumber ?? string.Empty,
            });
    }

    public Task NothingMoreSentAsync(int id, byte[]? rowVersion, string? reason, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("inventory.usp_TransferOrder_NothingMoreSent", ReasonParameters(id, rowVersion, reason, userId), cancellationToken);

    public Task CancelAsync(int id, byte[]? rowVersion, string? reason, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("inventory.usp_TransferOrder_Cancel", ReasonParameters(id, rowVersion, reason, userId), cancellationToken);

    public Task ReversePostingAsync(
        int postingId, byte[]? rowVersion, string? reason, DateOnly? date, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@PostingId", postingId, DbType.Int32);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@Reason", Trimmed(reason), DbType.String, size: 300);
        parameters.Add("@Date", ToDate(date), DbType.Date);
        parameters.Add("@UserId", userId, DbType.Int32);
        return ExecuteAsync("inventory.usp_TransferPosting_Reverse", parameters, cancellationToken, batch: true);
    }

    public Task SetEtaAsync(int postingId, byte[]? rowVersion, DateOnly? eta, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@PostingId", postingId, DbType.Int32);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@Eta", ToDate(eta), DbType.Date);
        parameters.Add("@UserId", userId, DbType.Int32);
        return ExecuteAsync("inventory.usp_TransferPosting_SetEta", parameters, cancellationToken);
    }

    public async Task<int> CreateReturnAsync(int id, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await ExecuteAsync("inventory.usp_TransferOrder_CreateReturn", parameters, cancellationToken);
        return parameters.Get<int?>("@NewId") ?? 0;
    }

    /* ── files ────────────────────────────────────────────────────────────────────────────────── */

    public async Task<int> AddFileAsync(
        int transferOrderId, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@TransferOrderId", transferOrderId, DbType.Int32);
        parameters.Add("@FileName", fileName, DbType.String, size: 255);
        parameters.Add("@ContentType", contentType, DbType.String, size: 100);
        parameters.Add("@SizeBytes", content.Length, DbType.Int32);
        parameters.Add("@Content", content, DbType.Binary, size: -1);
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        parameters.Add("@AttachmentTypeId", fields.AttachmentTypeId, DbType.Int32);
        parameters.Add("@DocumentDate", ToDate(fields.DocumentDate), DbType.Date);
        parameters.Add("@Note", fields.Note, DbType.String, size: 500);

        await ExecuteAsync("inventory.usp_TransferOrder_File_Add", parameters, cancellationToken);
        return parameters.Get<int>("@NewId");
    }

    public async Task<IReadOnlyList<DocumentFileDto>> ListFilesAsync(
        int transferOrderId, int? attachmentTypeId = null, int? fileId = null, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        var rows = await connection.QueryAsync<DocumentFileDto>(new CommandDefinition(
            "inventory.usp_TransferOrder_File_List",
            new { TransferOrderId = transferOrderId, AttachmentTypeId = attachmentTypeId, FileId = fileId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

        return rows.AsList();
    }

    public async Task<DocumentFileDto?> UpdateFileAsync(
        int fileId, DocumentFileEdit edit, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", fileId, DbType.Int32);
        parameters.Add("@AttachmentTypeId", edit.Fields.AttachmentTypeId, DbType.Int32);
        parameters.Add("@DocumentDate", ToDate(edit.Fields.DocumentDate), DbType.Date);
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
                "inventory.usp_TransferOrder_File_Update", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<TransferOrderFileContent?> GetFileAsync(int fileId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        return await connection.QuerySingleOrDefaultAsync<TransferOrderFileContent>(new CommandDefinition(
            "inventory.usp_TransferOrder_File_Get", new { Id = fileId },
            commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    public Task DeleteFileAsync(int fileId, int userId, CancellationToken cancellationToken = default)
        => ExecuteAsync("inventory.usp_TransferOrder_File_Delete", new { Id = fileId, UserId = userId }, cancellationToken);

    /* ── plumbing ─────────────────────────────────────────────────────────────────────────────── */

    private static DynamicParameters OrderParameters(int id, byte[]? rowVersion, int userId)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@UserId", userId, DbType.Int32);
        return parameters;
    }

    private static DynamicParameters ReasonParameters(int id, byte[]? rowVersion, string? reason, int userId)
    {
        var parameters = OrderParameters(id, rowVersion, userId);
        // Blank is NULL: the procedure then says the reason is required, in its own words, after the action's refusals.
        parameters.Add("@Reason", Trimmed(reason), DbType.String, size: 300);
        return parameters;
    }

    private static DynamicParameters DispatchParameters(
        int id, DispatchTransferRequest request, byte[]? rowVersion, int userId, bool withEta)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@RowVersion", rowVersion, DbType.Binary, size: 8);
        parameters.Add("@Date", ToDate(request.Date), DbType.Date);
        if (withEta)
        {
            parameters.Add("@Eta", ToDate(request.Eta), DbType.Date);
        }

        parameters.Add("@ReferenceNo", Trimmed(request.ReferenceNo), DbType.String, size: 100);
        parameters.Add("@Notes", Trimmed(request.Notes), DbType.String, size: 1000);
        parameters.Add("@Lines", ToDispatchLineTable(request.Lines).AsTableValuedParameter(DispatchLineTypeName));
        parameters.Add("@UserId", userId, DbType.Int32);
        parameters.Add("@PostingId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        parameters.Add("@DocumentNumber", dbType: DbType.String, size: 30, direction: ParameterDirection.Output);
        return parameters;
    }

    private static IReadOnlyList<string> Messages(IEnumerable<MessageRow> rows)
        => rows.Select(r => r.Message).Where(m => !string.IsNullOrWhiteSpace(m)).Select(m => m!).ToList();

    /// <summary>
    /// One procedure call, run again if SQL Server made it the deadlock victim. The procedures are whole transactions, so
    /// the retry is clean: a killed call wrote nothing (its number sequences included). <paramref name="batch"/>: the
    /// postings, which work on every line of the order and its ledger, get the batch command timeout.
    /// </summary>
    private async Task ExecuteAsync(string procedure, object parameters, CancellationToken cancellationToken, bool batch = false)
    {
        try
        {
            await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                await connection.ExecuteAsync(new CommandDefinition(
                    procedure, parameters, commandTimeout: batch ? _connectionFactory.BatchCommandTimeout : null,
                    commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            }, cancellationToken);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>A call whose result sets are read by <paramref name="read"/>, with the same retry and refusal handling.</summary>
    private async Task<T> QueryMultipleAsync<T>(
        string procedure, object parameters, int? commandTimeout, Func<SqlMapper.GridReader, Task<T>> read,
        CancellationToken cancellationToken)
    {
        try
        {
            return await SqlRetry.OnDeadlockAsync(async () =>
            {
                await using var connection = _connectionFactory.Create();
                using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
                    procedure, parameters, commandTimeout: commandTimeout,
                    commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
                var result = await read(multi);

                // Drain what is left, so an error raised after the last set read still reaches us as an exception.
                while (!multi.IsConsumed)
                {
                    await multi.ReadAsync();
                }

                return result;
            }, cancellationToken);
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>
    /// The lines as a <see cref="DataTable"/> shaped like inventory.tvp_TransferOrderLine. COLUMN ORDER IS THE TYPE'S
    /// ORDER AND IS LOAD-BEARING (a table-valued parameter is sent positionally); types declared, not inferred.
    ///
    /// NUMBERED 1..n in the order of the numbers sent (then as sent), as the page draws them: the procedure's "Line {n}:"
    /// sentences then point at the row the reader sees, and two lines sent with one number cannot break the type's key.
    /// </summary>
    private static DataTable ToOrderLineTable(IReadOnlyList<TransferOrderLineRequest>? lines)
    {
        var table = new DataTable();
        table.Columns.Add("LineNumber", typeof(int));
        table.Columns.Add("ItemId", typeof(int));
        table.Columns.Add("ItemUnitId", typeof(int));
        table.Columns.Add("Quantity", typeof(int));
        table.Columns.Add("Notes", typeof(string));

        var lineNumber = 1;
        foreach (var line in (lines ?? []).Select((l, i) => (Line: l, Index: i)).OrderBy(x => x.Line.LineNumber).ThenBy(x => x.Index).Select(x => x.Line))
        {
            table.Rows.Add(lineNumber++, line.ItemId, line.ItemUnitId, line.Quantity, (object?)Trimmed(line.Notes) ?? DBNull.Value);
        }

        return table;
    }

    /// <summary>inventory.tvp_TransferDispatchLine: (TransferOrderLineId, QuantityBase), the order line its key.</summary>
    private static DataTable ToDispatchLineTable(IReadOnlyList<DispatchTransferLineRequest>? lines)
    {
        var table = new DataTable();
        table.Columns.Add("TransferOrderLineId", typeof(int));
        table.Columns.Add("QuantityBase", typeof(int));

        foreach (var line in lines ?? [])
        {
            table.Rows.Add(line.TransferOrderLineId, line.QuantityBase);
        }

        return table;
    }

    /// <summary>inventory.tvp_TransferReceiptLine: (DispatchLineId, ReceivedBase, NothingMoreWillArrive, LossReasonCode, LossNote).</summary>
    private static DataTable ToReceiptLineTable(IReadOnlyList<ReceiveTransferLineRequest>? lines)
    {
        var table = new DataTable();
        table.Columns.Add("DispatchLineId", typeof(int));
        table.Columns.Add("ReceivedBase", typeof(int));
        table.Columns.Add("NothingMoreWillArrive", typeof(bool));
        table.Columns.Add("LossReasonCode", typeof(string));
        table.Columns.Add("LossNote", typeof(string));

        foreach (var line in lines ?? [])
        {
            table.Rows.Add(
                line.DispatchLineId,
                line.ReceivedBase,
                line.NothingMoreWillArrive,
                (object?)TransferLossReasons.Normalize(line.LossReasonCode) ?? DBNull.Value,
                (object?)Trimmed(line.LossNote) ?? DBNull.Value);
        }

        return table;
    }

    private static DateTime? ToDate(DateOnly? value) => value?.ToDateTime(TimeOnly.MinValue);

    private static DateOnly? ToDateOnly(DateTime? value) => value is { } v ? DateOnly.FromDateTime(v) : null;

    private static string? Trimmed(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}
