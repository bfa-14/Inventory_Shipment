using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Inventory.Transfers;
using Inventory_Shipment.Model.Enums;
using Inventory_Shipment.Repository.Database;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

/// <summary>
/// (93) BATCH, SERIAL AND EXPIRY ON TRANSFERS over script 93's procedures. Every rule is the database's: the dispatch's
/// in inventory.fn_TransferDispatch_TrackingProblems (read by Check and by the posting, one set of sentences), the
/// receipt's in the receive core, the states of a row in usp_TransferPosting_Tracking. This part shapes the two new
/// table types and reads the rows back.
///
/// 90'S TABLE TYPES ARE UNTOUCHED (B15): the rows travel in separate table-valued parameters, sent only when a line
/// carries rows - an omitted TVP is an empty table to the procedure, so an untracked posting is exactly 90's call.
/// </summary>
public sealed partial class TransferOrderRepository
{
    /* Matched by TYPE NAME on the server. Created by script 93 (5.3.4); a later change takes a new type. */
    private const string DispatchTrackingTypeName = "inventory.tvp_TransferDispatchTracking";
    private const string ReceiptTrackingTypeName = "inventory.tvp_TransferReceiptTracking";

    /// <summary>One row of fn_TransferDispatch_TrackingProblems, as usp_TransferOrder_CheckDispatchTracking returns it.</summary>
    private sealed class ProblemRow
    {
        public int Seq { get; init; }
        public string? Severity { get; init; }
        public int? TransferOrderLineId { get; init; }
        public int? LineNumber { get; init; }
        public int? RowNumber { get; init; }
        public string? Message { get; init; }
    }

    public async Task<IReadOnlyList<TransferTrackingProblemDto>> CheckDispatchTrackingAsync(
        int id, IReadOnlyList<DispatchTransferLineRequest>? lines, int? forLineId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@Id", id, DbType.Int32);
        parameters.Add("@Lines", ToDispatchLineTable(lines).AsTableValuedParameter(DispatchLineTypeName));
        // Always sent here, even empty: Check is script 93's own procedure, and "no rows" is one of the answers it gives.
        parameters.Add("@Tracking", ToDispatchTrackingTable(lines).AsTableValuedParameter(DispatchTrackingTypeName));
        parameters.Add("@ForLineId", forLineId, DbType.Int32);

        await using var connection = _connectionFactory.Create();
        try
        {
            // Read only, no lock: 10,000 serials are checked in well under the ordinary timeout (test s).
            var rows = await connection.QueryAsync<ProblemRow>(new CommandDefinition(
                "inventory.usp_TransferOrder_CheckDispatchTracking", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return rows.Select(r => new TransferTrackingProblemDto
            {
                Seq = r.Seq,
                Severity = string.Equals(r.Severity, TransferTrackingSeverities.Warning, StringComparison.OrdinalIgnoreCase)
                    ? TransferTrackingSeverities.Warning
                    : TransferTrackingSeverities.Error,
                TransferOrderLineId = r.TransferOrderLineId,
                LineNumber = r.LineNumber,
                RowNumber = r.RowNumber,
                Message = r.Message ?? string.Empty,
            }).ToList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>One row of usp_TransferPosting_Tracking (dates as the reader gives them).</summary>
    private sealed class TrackingRow
    {
        public int Id { get; init; }
        public int PostingLineId { get; init; }
        public int PostingLineNumber { get; init; }
        public int ItemId { get; init; }
        public string? ItemCode { get; init; }
        public int RowNumber { get; init; }
        public TrackingKind Kind { get; init; }
        public string? BatchNo { get; init; }
        public string? SerialNo { get; init; }
        public DateTime? ExpiryDate { get; init; }
        public int QuantityBase { get; init; }
        public int LostBase { get; init; }
        public int SettledBase { get; init; }
        public int OnTheWayBase { get; init; }
        public int? DispatchTrackingId { get; init; }
        public string? DispatchNumber { get; init; }
        public string? State { get; init; }
        public string? StateText { get; init; }
    }

    public async Task<IReadOnlyList<TransferTrackingRowDto>> PostingTrackingAsync(
        int postingId, bool onTheWayOnly, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            var rows = await connection.QueryAsync<TrackingRow>(new CommandDefinition(
                "inventory.usp_TransferPosting_Tracking", new { PostingId = postingId, OnTheWayOnly = onTheWayOnly },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return rows.Select(r => new TransferTrackingRowDto
            {
                Id = r.Id,
                PostingLineId = r.PostingLineId,
                PostingLineNumber = r.PostingLineNumber,
                ItemId = r.ItemId,
                ItemCode = r.ItemCode ?? string.Empty,
                RowNumber = r.RowNumber,
                Kind = r.Kind,
                SerialNo = r.SerialNo,
                BatchNo = r.BatchNo,
                ExpiryDate = ToDateOnly(r.ExpiryDate),
                QuantityBase = r.QuantityBase,
                LostBase = r.LostBase,
                SettledBase = r.SettledBase,
                OnTheWayBase = r.OnTheWayBase,
                DispatchTrackingId = r.DispatchTrackingId,
                DispatchNumber = r.DispatchNumber,
                State = r.State ?? string.Empty,
                StateText = r.StateText ?? string.Empty,
            }).ToList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>One serial received into the order's From and not sent since.</summary>
    private sealed class SuggestionRow
    {
        public string? SerialNo { get; init; }
        public DateTime? ExpiryDate { get; init; }
        public string? ReceivedByNumber { get; init; }
        public DateTime? ReceivedOn { get; init; }
    }

    public async Task<TransferTrackingSuggestionsDto?> TrackingSuggestionsAsync(
        int id, int transferOrderLineId, CancellationToken cancellationToken = default)
    {
        await using var connection = _connectionFactory.Create();
        try
        {
            // ONE CALL, BOTH ANSWERS: result 1 the serials (none for any kind but Serial, B12), result 2 the line's
            // TrackingKind now (2 / 1 / 3 / NULL). A line that is not on the order is the procedure's 62006 (404).
            using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
                "inventory.usp_TransferOrder_TrackingSuggestions", new { Id = id, TransferOrderLineId = transferOrderLineId },
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));
            var rows = (await multi.ReadAsync<SuggestionRow>()).AsList();
            var kind = await multi.ReadSingleOrDefaultAsync<byte?>();

            return new TransferTrackingSuggestionsDto
            {
                TrackingKind = kind is { } k ? (TrackingKind)k : null,
                Serials = rows.Where(r => !string.IsNullOrEmpty(r.SerialNo)).Select(r => new TransferSerialSuggestionDto
                {
                    SerialNo = r.SerialNo!,
                    ExpiryDate = ToDateOnly(r.ExpiryDate),
                    ReceivedByNumber = r.ReceivedByNumber,
                    ReceivedOn = ToDateOnly(r.ReceivedOn),
                }).ToList(),
            };
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /* ── the two table types ──────────────────────────────────────────────────────────────────── */

    /// <summary>@Tracking of Dispatch and Dispatch and receive, only when a line carries rows (an omitted TVP is empty).</summary>
    private static void AddDispatchTracking(DynamicParameters parameters, IReadOnlyList<DispatchTransferLineRequest>? lines)
    {
        if ((lines ?? []).Any(l => l?.Tracking is { Count: > 0 }))
        {
            parameters.Add("@Tracking", ToDispatchTrackingTable(lines).AsTableValuedParameter(DispatchTrackingTypeName));
        }
    }

    /// <summary>@Tracking of Receive, only when a line carries rows.</summary>
    private static void AddReceiptTracking(DynamicParameters parameters, IReadOnlyList<ReceiveTransferLineRequest>? lines)
    {
        if ((lines ?? []).Any(l => l?.Tracking is { Count: > 0 }))
        {
            parameters.Add("@Tracking", ToReceiptTrackingTable(lines).AsTableValuedParameter(ReceiptTrackingTypeName));
        }
    }

    /// <summary>
    /// inventory.tvp_TransferDispatchTracking: (TransferOrderLineId, RowNumber, BatchNo, SerialNo, ExpiryDate,
    /// QuantityBase). COLUMN ORDER IS THE TYPE'S AND IS LOAD-BEARING. RowNumber = the row's place in its line's list,
    /// 1-based, so the database's "row {r}" is the row the dialog shows. The numbers go as typed (blank = NULL): the
    /// database trims and capitalises them, one rule (B4).
    /// </summary>
    private static DataTable ToDispatchTrackingTable(IReadOnlyList<DispatchTransferLineRequest>? lines)
    {
        var table = new DataTable();
        table.Columns.Add("TransferOrderLineId", typeof(int));
        table.Columns.Add("RowNumber", typeof(int));
        table.Columns.Add("BatchNo", typeof(string));
        table.Columns.Add("SerialNo", typeof(string));
        table.Columns.Add("ExpiryDate", typeof(DateTime));
        table.Columns.Add("QuantityBase", typeof(int));

        // An empty row (null) is refused by the service first; never a NullReferenceException here. A row keeps its place
        // in the request as its RowNumber, so the database's "row {r}" is the row the dialog shows.
        foreach (var line in (lines ?? []).Where(l => l is not null))
        {
            var rowNumber = 1;
            foreach (var row in line.Tracking ?? [])
            {
                if (row is null)
                {
                    rowNumber++;
                    continue;
                }

                table.Rows.Add(
                    line.TransferOrderLineId,
                    rowNumber++,
                    string.IsNullOrEmpty(row.BatchNo) ? DBNull.Value : (object)row.BatchNo,
                    string.IsNullOrEmpty(row.SerialNo) ? DBNull.Value : (object)row.SerialNo,
                    (object?)ToDate(row.ExpiryDate) ?? DBNull.Value,
                    row.QuantityBase);
            }
        }

        return table;
    }

    /// <summary>
    /// The pieces a receipt line says arrived: a line that carries tracking rows is sent with the SUM of its rows'
    /// ReceivedBase, whatever the client put on the line (5.5.4: the rows are the truth, and the receive core refuses a
    /// line whose rows add up to another figure). Done here, where the line becomes the table's row, so no field a later
    /// script adds to the request is lost on a copy. A sum beyond an INT goes as the largest one, refused as "more than
    /// is on the way".
    /// </summary>
    private static int ReceivedBaseOf(ReceiveTransferLineRequest line)
        => line.Tracking is { Count: > 0 } rows
            ? (int)Math.Clamp(rows.Where(r => r is not null).Sum(r => (long)r.ReceivedBase), int.MinValue, int.MaxValue)
            : line.ReceivedBase;

    /// <summary>inventory.tvp_TransferReceiptTracking: (DispatchTrackingId, ReceivedBase, LostBase), the dispatch row its key.</summary>
    private static DataTable ToReceiptTrackingTable(IReadOnlyList<ReceiveTransferLineRequest>? lines)
    {
        var table = new DataTable();
        table.Columns.Add("DispatchTrackingId", typeof(int));
        table.Columns.Add("ReceivedBase", typeof(int));
        table.Columns.Add("LostBase", typeof(int));

        foreach (var row in (lines ?? []).Where(l => l is not null).SelectMany(l => l.Tracking ?? []).Where(r => r is not null))
        {
            table.Rows.Add(row.DispatchTrackingId, row.ReceivedBase, row.LostBase);
        }

        return table;
    }
}
