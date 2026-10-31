using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Inventory.StockLevels;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Stock levels from Excel (Inventory › Stock Levels › Import from Excel…), with inventory.stocklevels.edit: the template,
/// a validate that judges every row and writes nothing, the error report, and the import of the rows posted back - judged
/// again by the same database function and written in ONE transaction.
/// </summary>
public interface IStockLevelImportService
{
    /// <summary>Import_Stock_Levels_Template.xlsx: sheets Levels, Instructions and Example.</summary>
    Result<(byte[] Content, string FileName)> GenerateTemplate(IReadOnlySet<string> permissions);

    /// <summary>
    /// Reads the file and judges every row (Valid, Warning, Error, Unchanged, with the action and the message). A 400 with
    /// code INVALID_FILE is the file's own problem; a bad row is not a failure of the call.
    /// </summary>
    Task<Result<StockLevelImportValidation>> ValidateAsync(
        Stream file, string fileName, long fileLength, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>Import_Stock_Levels_Errors.xlsx: the Warning and Error rows, to correct and upload again.</summary>
    Result<(byte[] Content, string FileName)> GenerateErrorReport(
        IReadOnlyList<StockLevelImportRow> rows, IReadOnlySet<string> permissions);

    Task<Result<StockLevelImportResult>> ImportAsync(
        StockLevelImportRequest request, int userId, IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);
}
