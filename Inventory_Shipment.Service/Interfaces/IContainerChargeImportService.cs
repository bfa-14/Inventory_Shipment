using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Logistics;

namespace Inventory_Shipment.Service.Interfaces;

/// <summary>
/// Container charges imported from Excel (Logistics › Containers). containers.charges.create for everything;
/// importing with post = true needs containers.charges.post as well. Nothing is created before the import:
/// the template, the validation and the error report only read.
/// </summary>
public interface IContainerChargeImportService
{
    /// <summary>"Import_Container_Charges_Template.xlsx": Charges (two example rows), Instructions, Lists.</summary>
    Task<Result<(byte[] Content, string FileName)>> GenerateTemplateAsync(
        IReadOnlySet<string> permissions, CancellationToken cancellationToken = default);

    /// <summary>
    /// Reads the file and judges every row (Valid, Warning or Error, with the message). A 400 INVALID_FILE is
    /// the file's own problem; a bad row is not a failure of the call. <paramref name="today"/> is the
    /// browser's date, used for a blank Charge Date (null = the server's date).
    /// </summary>
    Task<Result<ContainerChargeImportValidation>> ValidateAsync(
        Stream file, string fileName, long fileLength, DateOnly? today, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);

    /// <summary>The Warning and Error rows as a workbook to correct and upload again.</summary>
    Result<(byte[] Content, string FileName)> GenerateErrorReport(
        IReadOnlyList<ContainerChargeImportValidatedRow> rows, IReadOnlySet<string> permissions);

    /// <summary>
    /// Creates the rows' charges (Error rows skipped), each on its own: a row refused at creation or at posting
    /// is reported with its reason and the others go on. 403 before anything is created when post = true and
    /// the caller cannot post.
    /// </summary>
    Task<Result<ContainerChargeImportResult>> ImportAsync(
        ContainerChargeImportRequest request, int userId, IReadOnlySet<string> permissions,
        CancellationToken cancellationToken = default);
}
