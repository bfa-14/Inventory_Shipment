using System.ComponentModel.DataAnnotations;

namespace Inventory_Shipment.Model.DTOs.Logistics;

/// <summary>
/// (111) What a shipment stage does when a container is moved to it (logistics.ShipmentStages.Kind).
/// </summary>
public static class ShipmentStageKinds
{
    /// <summary>A leg From → To of the stage's movement type, started on the stage's date.</summary>
    public const byte Leg = 1;

    /// <summary>The leg reaching the stage's place is completed.</summary>
    public const byte Arrive = 2;

    /// <summary>The last leg completed (one more leg when needed) and the goods receipt posted for the full quantity.</summary>
    public const byte Offload = 3;

    public static string Name(byte kind) => kind switch
    {
        Leg => "Leg",
        Arrive => "Arrival",
        Offload => "Offload",
        _ => string.Empty,
    };
}

/// <summary>(111) What moving a container to a stage does (logistics.usp_ShipmentStage_Preview).</summary>
public static class ShipmentStageActions
{
    public const string StartLeg = "StartLeg";
    public const string Complete = "Complete";
    public const string CompleteThenDeliver = "CompleteThenDeliver";
    public const string Deliver = "Deliver";
    public const string Receive = "Receive";
}

public sealed class ShipmentStageDto
{
    public int Id { get; init; }
    public string StageName { get; init; } = string.Empty;
    public byte Kind { get; init; }
    public string KindName => ShipmentStageKinds.Name(Kind);
    public int? MovementTypeId { get; init; }
    public string? MovementTypeName { get; init; }
    public string? MovementTypeStage { get; init; }

    /// <summary>A leg's From; null = the container's port of loading (its first leg).</summary>
    public int? FromPlaceId { get; init; }

    public string? FromPlaceName { get; init; }
    public int ToPlaceId { get; init; }
    public string ToPlaceName { get; init; } = string.Empty;
    public int SortOrder { get; init; }
    public bool IsActive { get; init; }
    public byte[] RowVersion { get; init; } = [];
}

public sealed class SaveShipmentStageRequest
{
    [Required]
    [StringLength(100, MinimumLength = 1)]
    public string StageName { get; init; } = string.Empty;

    [Range(1, 3)]
    public byte Kind { get; init; }

    public int? MovementTypeId { get; init; }
    public int? FromPlaceId { get; init; }

    [Range(1, int.MaxValue)]
    public int ToPlaceId { get; init; }

    public int SortOrder { get; init; }
    public bool IsActive { get; init; } = true;
    public string? RowVersion { get; init; }
}

/// <summary>(111) How many containers stand at each stage, and the ones the stages do not describe.</summary>
public sealed class ShipmentStageCheckDto
{
    public IReadOnlyList<ShipmentStageCountDto> Stages { get; init; } = [];
    public IReadOnlyList<ShipmentStageMisfitDto> NotOnAStage { get; init; } = [];
}

public sealed class ShipmentStageCountDto
{
    /// <summary>Null for Pending, Offloaded without an Offload stage and "Not on a stage".</summary>
    public int? StageId { get; init; }

    public string StageName { get; init; } = string.Empty;

    /// <summary>0 Pending, 1-3 the stage's kind.</summary>
    public byte? StageKind { get; init; }

    public bool FitsStages { get; init; }
    public int Containers { get; init; }
}

public sealed class ShipmentStageMisfitDto
{
    public int ContainerId { get; init; }
    public string ContainerRef { get; init; } = string.Empty;
    public string? ContainerNo { get; init; }
    public byte ContainerStatus { get; init; }

    /// <summary>"Sea freight Chennai → Dar es Salaam | Inland transport Dar es Salaam → Kasumbalesa (in progress)".</summary>
    public string? Legs { get; init; }
}

public sealed class ShipmentStagePreviewRequest
{
    [Range(1, int.MaxValue)]
    public int StageId { get; init; }

    public IReadOnlyList<int> ContainerIds { get; init; } = [];
}

/// <summary>(111) One container moved to a stage: what it does, or why it cannot.</summary>
public sealed class ShipmentStagePreviewRowDto
{
    public int ContainerId { get; init; }
    public bool Found { get; init; }
    public string? ContainerRef { get; init; }
    public string? ContainerNo { get; init; }
    public byte? ContainerStatus { get; init; }
    public bool IsDraft { get; init; }
    public int? CurrentStageId { get; init; }
    public string? CurrentStageName { get; init; }

    /// <summary><see cref="ShipmentStageActions"/>; null when it cannot move.</summary>
    public string? Action { get; init; }

    public bool CanMove { get; init; }

    /// <summary>Already at the stage: skipped, not refused.</summary>
    public bool AlreadyThere { get; init; }

    public string? Reason { get; init; }
    public int? MovementId { get; init; }
    public string? MovementNo { get; init; }
    public int MovementContainerCount { get; init; }
    public int? PlaceId { get; init; }
    public string? PlaceName { get; init; }
    public string? WarehouseCode { get; init; }

    /// <summary>An Offload stage: "No warehouse on the container: its goods receipt will wait for one."</summary>
    public string? ReceiveWarning { get; init; }
}

public sealed class ShipmentStageMatchRequest
{
    public IReadOnlyList<string?> Numbers { get; init; } = [];
}

public sealed class ShipmentStageMatchRowDto
{
    public int RowNo { get; init; }
    public string? InputNumber { get; init; }

    /// <summary>Null when not found or found twice (<see cref="Matches"/>).</summary>
    public int? ContainerId { get; init; }

    public string? ContainerRef { get; init; }
    public string? ContainerNo { get; init; }
    public int Matches { get; init; }
}

public sealed class ApplyShipmentStageRequest
{
    public IReadOnlyList<ApplyShipmentStageItem> Items { get; init; } = [];
}

/// <summary>One container to one stage, on a date; a leg may carry its truck (or vessel) no. and ETA.</summary>
public sealed class ApplyShipmentStageItem
{
    [Range(1, int.MaxValue)]
    public int ContainerId { get; init; }

    [Range(1, int.MaxValue)]
    public int StageId { get; init; }

    public DateOnly? Date { get; init; }

    [StringLength(100)]
    public string? VehicleOrVessel { get; init; }

    public DateOnly? Eta { get; init; }
}

public sealed class ApplyShipmentStageResultDto
{
    public IReadOnlyList<ApplyShipmentStageItemResultDto> Items { get; init; } = [];
    public int Moved { get; init; }
    public int Skipped { get; init; }
    public int Refused { get; init; }

    /// <summary>"22 containers moved, 1 already there, 2 refused."</summary>
    public string Message { get; init; } = string.Empty;
}

public sealed class ApplyShipmentStageItemResultDto
{
    public int ContainerId { get; init; }
    public string? ContainerRef { get; init; }
    public string? StageName { get; init; }

    /// <summary>Moved (or offloaded) - its goods receipt may still have been refused: see <see cref="Warning"/>.</summary>
    public bool Ok { get; init; }

    /// <summary>Already at the stage: nothing done.</summary>
    public bool Skipped { get; init; }

    public string Message { get; init; } = string.Empty;
    public string? Code { get; init; }

    /// <summary>The movements made or completed: "MOV-2026-000046".</summary>
    public IReadOnlyList<string> Movements { get; init; } = [];

    public int? GoodsReceiptId { get; init; }
    public string? GoodsReceiptNumber { get; init; }

    /// <summary>The leg moved but something after it did not: "Goods receipt not posted: ...".</summary>
    public string? Warning { get; init; }
}
