using System.Data;
using Dapper;
using Inventory_Shipment.Model.DTOs.Sales;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Interfaces;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Implementations;

public sealed class InvoiceImportRepository : IInvoiceImportRepository
{
    /// <summary>
    /// The table type's name as the server knows it. It must match sales.tvp_InvoiceImportRow
    /// exactly — SQL Server matches a table-valued parameter by type name, and a wrong one fails with
    /// a message about an "invalid parameter" that says nothing about the type.
    /// </summary>
    private const string RowTypeName = "sales.tvp_InvoiceImportRow";

    private readonly ISqlConnectionFactory _connectionFactory;

    public InvoiceImportRepository(ISqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<IReadOnlyList<InvoiceImportValidatedRow>> ValidateAsync(
        int branchId,
        int defaultWarehouseId,
        int? priceListId,
        bool allowPriceOverride,
        decimal maxDiscountPercent,
        bool checkStock,
        string? documentTypeCode,
        IReadOnlyList<InvoiceImportRow> rows,
        CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", branchId, DbType.Int32);
        parameters.Add("@DefaultWarehouseId", defaultWarehouseId, DbType.Int32);
        // NULL IS STOCK MODE, not a missing value. An Inventory In / Out document has no selling
        // price: the procedure skips every pricing check and reads the Unit Price column as the unit
        // cost. Sent as a real NULL rather than 0, which would be a price list nobody owns.
        parameters.Add("@PriceListId", priceListId, DbType.Int32);
        parameters.Add("@AllowPriceOverride", allowPriceOverride, DbType.Boolean);
        parameters.Add("@MaxDiscountPercent", maxDiscountPercent, DbType.Decimal);
        parameters.Add("@Rows", ToTable(rows).AsTableValuedParameter(RowTypeName));
        parameters.Add("@CheckStock", checkStock, DbType.Boolean);
        // The page's type: rows naming another one come back as Errors, and it picks the unit preference.
        parameters.Add("@DocumentTypeCode", documentTypeCode, DbType.String, size: 20);

        await using var connection = _connectionFactory.Create();
        try
        {
            var result = await connection.QueryAsync<InvoiceImportValidatedRow>(new CommandDefinition(
                "sales.usp_InvoiceImport_Validate", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return result.AsList();
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    public async Task<int> LogAsync(
        InvoiceImportLogRequest request, int userId, CancellationToken cancellationToken = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", request.BranchId, DbType.Int32);
        parameters.Add("@WarehouseId", request.WarehouseId, DbType.Int32);
        parameters.Add("@PriceListId", request.PriceListId, DbType.Int32);
        parameters.Add("@FileName", request.FileName, DbType.String, size: 255);
        parameters.Add("@TotalRows", request.TotalRows, DbType.Int32);
        parameters.Add("@ImportedRows", request.ImportedRows, DbType.Int32);
        parameters.Add("@WarningRows", request.WarningRows, DbType.Int32);
        parameters.Add("@RejectedRows", request.RejectedRows, DbType.Int32);
        parameters.Add("@DraftReference", request.DraftReference, DbType.String, size: 50);
        parameters.Add("@InvoiceId", request.InvoiceId, DbType.Int32);
        parameters.Add("@ImportedBy", userId, DbType.Int32);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await using var connection = _connectionFactory.Create();
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "sales.usp_InvoiceImport_Log", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: cancellationToken));

            return parameters.Get<int>("@NewId");
        }
        catch (SqlException ex) when (SqlErrors.IsBusinessRule(ex))
        {
            throw SqlErrors.Wrap(ex);
        }
    }

    /// <summary>
    /// The rows as a <see cref="DataTable"/> shaped like sales.tvp_InvoiceImportRow.
    ///
    /// THE COLUMN ORDER IS THE TYPE'S ORDER AND IS LOAD-BEARING. A table-valued parameter is sent
    /// positionally: SQL Server maps column 1 to column 1, whatever either is called. Reordering the
    /// Add calls below silently puts the quantity in the price column, which validates cleanly and
    /// imports the wrong numbers — so this list is kept in the same order as the CREATE TYPE, and
    /// nothing here is sorted or projected on the way in.
    ///
    /// TYPES ARE DECLARED EXPLICITLY for the same reason. An inferred column type from an all-null
    /// column comes out as string, and the server then refuses the whole batch over a column nobody
    /// filled in.
    /// </summary>
    private static DataTable ToTable(IReadOnlyList<InvoiceImportRow> rows)
    {
        var table = new DataTable();
        table.Columns.Add("RowNumber", typeof(int));
        table.Columns.Add("ItemRef", typeof(string));
        table.Columns.Add("UnitName", typeof(string));
        table.Columns.Add("WarehouseRef", typeof(string));
        table.Columns.Add("Quantity", typeof(decimal));
        table.Columns.Add("RawQuantity", typeof(string));
        table.Columns.Add("UnitPrice", typeof(decimal));
        table.Columns.Add("DiscountPercent", typeof(decimal));
        table.Columns.Add("ExpiryDate", typeof(DateTime));
        table.Columns.Add("RawExpiryDate", typeof(string));
        table.Columns.Add("Notes", typeof(string));
        // LAST, because script 20 re-created the type with this column at the end — and the parameter is positional.
        table.Columns.Add("DocumentTypeCode", typeof(string));

        foreach (var row in rows)
        {
            table.Rows.Add(
                row.RowNumber,
                (object?)row.ItemRef ?? DBNull.Value,
                (object?)row.UnitName ?? DBNull.Value,
                (object?)row.WarehouseRef ?? DBNull.Value,
                (object?)row.Quantity ?? DBNull.Value,
                (object?)row.RawQuantity ?? DBNull.Value,
                (object?)row.UnitPrice ?? DBNull.Value,
                (object?)row.DiscountPercent ?? DBNull.Value,
                (object?)row.ExpiryDate ?? DBNull.Value,
                (object?)row.RawExpiryDate ?? DBNull.Value,
                (object?)row.Notes ?? DBNull.Value,
                (object?)row.DocumentTypeCode ?? DBNull.Value);
        }

        return table;
    }
}
