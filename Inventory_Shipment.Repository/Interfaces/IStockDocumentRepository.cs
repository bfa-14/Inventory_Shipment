using Inventory_Shipment.Model.DTOs.Documents;
using Inventory_Shipment.Model.DTOs.Inventory;

namespace Inventory_Shipment.Repository.Interfaces;

/// <summary>
/// Inventory In / Out documents and the stock ledger behind them.
///
/// EVERY RULE IS THE PROCEDURES'. Whether a document may be edited, whether posting it would take
/// stock below zero, what the reversal of a cancellation looks like — all of it is decided in SQL, in
/// one transaction with the write it guards. This layer carries parameters in and result sets out.
/// </summary>
public interface IStockDocumentRepository
{
    /// <summary>The configuration of all eight document kinds.</summary>
    Task<IReadOnlyList<DocumentTypeDto>> GetDocumentTypesAsync(CancellationToken cancellationToken = default);

    /// <summary>inventory.usp_DocumentType_Update — the configuration page's save. Throws 62000 / 62004 / 62006.</summary>
    Task UpdateDocumentTypeAsync(
        int id, UpdateDocumentTypeRequest request, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Reasons usable in one direction: 1 for In, -1 for Out, null for all.</summary>
    Task<IReadOnlyList<StockReasonDto>> GetStockReasonsAsync(short? direction, CancellationToken cancellationToken = default);

    /// <summary>Stock in one item and warehouse right now, in base units. Signed: it can be negative only if the ledger was forced.</summary>
    Task<decimal> GetOnHandAsync(int itemId, int warehouseId, CancellationToken cancellationToken = default);

    Task<(IReadOnlyList<StockDocumentListDto> Items, int TotalCount)> SearchAsync(
        StockDocumentQuery query, CancellationToken cancellationToken = default);

    /// <summary>The whole document: header, lines, files and audit, in one round trip. Null when there is no such document.</summary>
    Task<StockDocumentDto?> GetAsync(int id, CancellationToken cancellationToken = default);

    /// <summary>Creates or replaces a draft and returns its id. A full replace of the lines — see the request type.</summary>
    Task<int> SaveAsync(SaveStockDocumentRequest request, int? id, int userId, CancellationToken cancellationToken = default);

    /// <summary>Writes the ledger movements and closes the document. Assigns the number where the type numbers on posting.</summary>
    Task PostAsync(int id, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Writes reversal movements and marks the document Cancelled.</summary>
    Task CancelAsync(int id, string reason, byte[]? rowVersion, int userId, CancellationToken cancellationToken = default);

    /// <summary>Drafts only. A posted document is a record of something that happened and is never removed.</summary>
    Task DeleteAsync(int id, int userId, CancellationToken cancellationToken = default);

    /// <summary>The file with its type (required, used for the document's kind), date and note (script 52).</summary>
    Task<int> AddFileAsync(
        int documentId, string fileName, string contentType, byte[] content, DocumentFileFields fields, int userId,
        CancellationToken cancellationToken = default);

    /// <summary>The files of a document with their type, date and note, newest first; one type, or one file, when asked.</summary>
    Task<IReadOnlyList<DocumentFileDto>> ListFilesAsync(
        int documentId, int? attachmentTypeId = null, int? fileId = null, CancellationToken cancellationToken = default);

    /// <summary>
    /// The name, type, date and note of a file (the upload's checks) and, when content is given, its bytes; the file as
    /// it now stands.
    /// </summary>
    Task<DocumentFileDto?> UpdateFileAsync(
        int fileId, DocumentFileEdit edit, int userId, CancellationToken cancellationToken = default);

    /// <summary>One attachment WITH its bytes. Null when there is no such file.</summary>
    Task<StockDocumentFileContent?> GetFileAsync(int fileId, CancellationToken cancellationToken = default);

    Task DeleteFileAsync(int fileId, int userId, CancellationToken cancellationToken = default);
}

/// <summary>An attachment and its bytes — the only shape that carries content, so nothing else has to think about size.</summary>
public sealed class StockDocumentFileContent
{
    public int Id { get; init; }
    public int DocumentId { get; init; }
    public string FileName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public byte[] Content { get; init; } = [];
}
