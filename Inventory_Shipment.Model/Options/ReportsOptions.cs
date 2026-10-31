namespace Inventory_Shipment.Model.Options;

/// <summary>Bound from the "Reports" configuration section.</summary>
public sealed class ReportsOptions
{
    public const string SectionName = "Reports";

    /// <summary>
    /// The most files one Attachment Report download may take (script 101). Above it the download is refused and the
    /// reader is asked to narrow the filters: the files live in the database, and a ZIP of thousands is one long request.
    /// </summary>
    public int AttachmentZipMaxFiles { get; set; } = 500;

    /// <summary>The most bytes one Attachment Report download may take, before compression (2 GB).</summary>
    public long AttachmentZipMaxBytes { get; set; } = 2L * 1024 * 1024 * 1024;
}
