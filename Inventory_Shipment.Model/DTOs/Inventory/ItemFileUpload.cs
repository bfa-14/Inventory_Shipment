namespace Inventory_Shipment.Model.DTOs.Inventory;

/// <summary>
/// One uploaded file on its way into inventory.ItemFiles, described without any web types so the
/// service layer can validate it. The API fills this from the posted IFormFile.
/// </summary>
/// <param name="FileName">Name as the browser sent it; the service keeps only the file name part.</param>
/// <param name="ContentType">MIME type the browser reported; the service checks it against the allow-list.</param>
/// <param name="SizeBytes">Length the browser reported, checked before the stream is read.</param>
/// <param name="Content">The bytes, read only once the size and type pass.</param>
public sealed record ItemFileUpload(string? FileName, string? ContentType, long SizeBytes, Stream Content);
