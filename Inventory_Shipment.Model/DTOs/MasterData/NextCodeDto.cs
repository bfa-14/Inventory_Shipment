namespace Inventory_Shipment.Model.DTOs.MasterData;

/// <summary>A code the server suggests for a record about to be created. Only a suggestion - it stays editable.</summary>
public sealed class NextCodeDto
{
    public string SuggestedCode { get; init; } = string.Empty;
}
