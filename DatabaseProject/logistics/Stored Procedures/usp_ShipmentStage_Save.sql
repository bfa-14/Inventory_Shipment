CREATE   PROCEDURE logistics.usp_ShipmentStage_Save
    @Id             INT           = NULL,
    @StageName      NVARCHAR(100),
    @Kind           TINYINT,
    @MovementTypeId INT           = NULL,
    @FromPlaceId    INT           = NULL,
    @ToPlaceId      INT,
    @SortOrder      INT           = 0,
    @IsActive       BIT           = 1,
    @RowVersion     BINARY(8)     = NULL,
    @UserId         INT           = NULL,
    @NewId          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @StageName = NULLIF(LTRIM(RTRIM(@StageName)), N'');
    IF @StageName IS NULL THROW 70000, 'The stage name is required.', 1;
    IF @Kind IS NULL OR @Kind NOT IN (1, 2, 3) THROW 70000, 'Choose what the stage does: a leg, an arrival or the offload.', 1;
    IF @ToPlaceId IS NULL OR NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @ToPlaceId)
        THROW 70000, 'Choose the place the stage reaches.', 1;
    IF @Kind = 2 SELECT @MovementTypeId = NULL, @FromPlaceId = NULL;
    IF @Kind = 3 SET @FromPlaceId = NULL;
    IF @Kind <> 2 AND (@MovementTypeId IS NULL OR NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @MovementTypeId))
        THROW 70000, 'Choose the movement type the stage records.', 1;
    IF @FromPlaceId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @FromPlaceId)
        THROW 70000, 'The place the stage leaves from was not found.', 1;
    IF EXISTS (SELECT 1 FROM logistics.ShipmentStages WHERE StageName = @StageName AND (@Id IS NULL OR Id <> @Id))
        THROW 70001, 'A stage of this name already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO logistics.ShipmentStages (StageName, Kind, MovementTypeId, FromPlaceId, ToPlaceId, SortOrder, IsActive, CreatedBy)
        VALUES (@StageName, @Kind, @MovementTypeId, @FromPlaceId, @ToPlaceId, ISNULL(@SortOrder, 0), ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM logistics.ShipmentStages WHERE Id = @Id) THROW 70006, 'Shipment stage not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.ShipmentStages WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 70004, 'This stage was changed by another user. Reload the page and try again.', 1;
        UPDATE logistics.ShipmentStages
        SET StageName = @StageName, Kind = @Kind, MovementTypeId = @MovementTypeId, FromPlaceId = @FromPlaceId,
            ToPlaceId = @ToPlaceId, SortOrder = ISNULL(@SortOrder, 0), IsActive = ISNULL(@IsActive, 1),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END