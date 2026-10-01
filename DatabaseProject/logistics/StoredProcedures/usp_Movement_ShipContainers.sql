/* ================================================================== 5. A shipment for the chosen containers */

-- Confirms the draft containers (@ConfirmDrafts), creates ONE movement for all of them and starts it (@StartNow),
-- in one transaction. Places by default (Sea stage only): from the common port of loading to the common port of
-- destination of the containers. @UpdateContainers copies to the containers the values that change: for a vessel leg
-- (Sea, or a transshipment between two sea ports) the vessel, voyage, shipping line (the carrier's name) and ETA; for a
-- Sea movement also the ports, only when the container has none; for a road leg (Transit, Border, Delivery) the truck;
-- the B/L no. / date when given. Each changed container gets one audit line listing what changed.
-- Returns the movement (Id, MovementNo, Status, StartDate, Eta, ContainerCount, RowVersion) and @NewId.
CREATE   PROCEDURE logistics.usp_Movement_ShipContainers
    @ContainerIds     logistics.tvp_IdList READONLY,
    @MovementTypeId   INT            = NULL,   -- NULL = SEA
    @FromPlaceId      INT            = NULL,
    @ToPlaceId        INT            = NULL,
    @StartDate        DATE           = NULL,   -- NULL = today (planned date when @StartNow = 0)
    @Eta              DATE           = NULL,
    @CarrierPartyId   INT            = NULL,
    @VehicleOrVessel  NVARCHAR(100)  = NULL,
    @VoyageNo         NVARCHAR(30)   = NULL,
    @Reference        NVARCHAR(50)   = NULL,   -- booking / waybill / declaration...
    @BlNo             NVARCHAR(30)   = NULL,
    @BlDate           DATE           = NULL,
    @Notes            NVARCHAR(1000) = NULL,
    @StartNow         BIT            = 1,      -- 0 = the movement stays planned
    @ConfirmDrafts    BIT            = 1,
    @UpdateContainers BIT            = 1,
    @UserId           INT            = NULL,
    @NewId            INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @VehicleOrVessel = NULLIF(LTRIM(RTRIM(@VehicleOrVessel)), N'');
    SET @VoyageNo = NULLIF(LTRIM(RTRIM(@VoyageNo)), N'');
    SET @Reference = NULLIF(LTRIM(RTRIM(@Reference)), N'');
    SET @BlNo = NULLIF(LTRIM(RTRIM(@BlNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    IF @StartDate IS NULL SET @StartDate = CAST(SYSUTCDATETIME() AS DATE);
    SET @StartNow = ISNULL(@StartNow, 1);
    SET @ConfirmDrafts = ISNULL(@ConfirmDrafts, 1);
    SET @UpdateContainers = ISNULL(@UpdateContainers, 1);

    IF @MovementTypeId IS NULL
        SELECT @MovementTypeId = Id FROM masterdata.MovementTypes WHERE TypeCode = N'SEA' AND IsActive = 1;
    DECLARE @Stage NVARCHAR(10), @TypeCode NVARCHAR(10);
    SELECT @Stage = Stage, @TypeCode = TypeCode FROM masterdata.MovementTypes WHERE Id = @MovementTypeId AND IsActive = 1;
    IF @Stage IS NULL THROW 70000, 'Movement type not found or inactive.', 1;

    DECLARE @Ids TABLE (Id INT NOT NULL PRIMARY KEY);
    INSERT INTO @Ids (Id) SELECT Id FROM @ContainerIds;
    IF NOT EXISTS (SELECT 1 FROM @Ids) THROW 70000, 'Select at least one container.', 1;
    IF EXISTS (SELECT 1 FROM @Ids x WHERE NOT EXISTS (SELECT 1 FROM logistics.Containers c WHERE c.Id = x.Id))
        THROW 70006, 'A selected container no longer exists.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef
                        + CASE WHEN c.Status >= 6 THEN N' is already offloaded, closed or cancelled.'
                               ELSE N' is a draft: confirm it first, or let this shipment confirm the drafts.' END
    FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
    WHERE c.Status >= 6 OR (c.Status = 1 AND @ConfirmDrafts = 0 AND @StartNow = 1)
    ORDER BY c.ContainerRef;
    IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

    IF @Stage = N'Sea' AND @FromPlaceId IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id WHERE c.PortOfLoadingId IS NULL)
           OR (SELECT COUNT(DISTINCT c.PortOfLoadingId) FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id) > 1
            THROW 70000, 'Choose the departure port: the selected containers have no port of loading, or different ones.', 1;
        SELECT TOP (1) @FromPlaceId = c.PortOfLoadingId FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id;
    END
    IF @Stage = N'Sea' AND @ToPlaceId IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id WHERE c.PortOfDestinationId IS NULL)
           OR (SELECT COUNT(DISTINCT c.PortOfDestinationId) FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id) > 1
            THROW 70000, 'Choose the destination port: the selected containers have no port of destination, or different ones.', 1;
        SELECT TOP (1) @ToPlaceId = c.PortOfDestinationId FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id;
    END
    IF @FromPlaceId IS NULL OR @ToPlaceId IS NULL THROW 70000, 'Choose the departure and destination places.', 1;

    DECLARE @CarrierName NVARCHAR(100) = (SELECT LEFT(PartyName, 100) FROM masterdata.Parties WHERE Id = @CarrierPartyId);
    DECLARE @FromKind NVARCHAR(10) = (SELECT Kind FROM masterdata.Ports WHERE Id = @FromPlaceId),
            @ToKind   NVARCHAR(10) = (SELECT Kind FROM masterdata.Ports WHERE Id = @ToPlaceId);
    -- a vessel leg: sea freight, or a transshipment between two sea ports (feeder vessel, not inland transport);
    -- a road leg: the other legs that move (inland transport, border, delivery)
    DECLARE @VesselLeg BIT = CASE WHEN @Stage = N'Sea'
                                    OR (@Stage = N'Transit' AND @TypeCode <> N'INLAND' AND @FromKind = N'Sea' AND @ToKind = N'Sea')
                                  THEN 1 ELSE 0 END;
    DECLARE @RoadLeg BIT = CASE WHEN @VesselLeg = 0 AND @Stage IN (N'Transit', N'Border', N'Delivery') THEN 1 ELSE 0 END;
    DECLARE @MovementId INT, @Cid INT, @Ref NVARCHAR(30) = NULL, @MovementNo NVARCHAR(30);
    DECLARE @Changed TABLE (ContainerId INT NOT NULL PRIMARY KEY, Details NVARCHAR(450) NOT NULL);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. the drafts are confirmed
        IF @ConfirmDrafts = 1
        BEGIN
            DECLARE draft_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
                SELECT c.Id, c.ContainerRef FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
                WHERE c.Status = 1 ORDER BY c.ContainerRef;
            OPEN draft_cur;
            FETCH NEXT FROM draft_cur INTO @Cid, @Ref;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC logistics.usp_Container_Confirm @Id = @Cid, @UserId = @UserId;
                FETCH NEXT FROM draft_cur INTO @Cid, @Ref;
            END
            CLOSE draft_cur;
            DEALLOCATE draft_cur;
            SET @Ref = NULL;
        END

        -- 2. one movement for all of them, 3. started
        EXEC logistics.usp_Movement_Save
             @MovementTypeId  = @MovementTypeId,
             @FromPlaceId     = @FromPlaceId,
             @ToPlaceId       = @ToPlaceId,
             @PlannedDate     = @StartDate,
             @Eta             = @Eta,
             @CarrierPartyId  = @CarrierPartyId,
             @VehicleOrVessel = @VehicleOrVessel,
             @VoyageNo        = @VoyageNo,
             @Reference       = @Reference,
             @Notes           = @Notes,
             @ContainerIds    = @ContainerIds,
             @UserId          = @UserId,
             @NewId           = @MovementId OUTPUT;

        IF @StartNow = 1
            EXEC logistics.usp_Movement_SetStatus @Id = @MovementId, @Action = N'Start', @Date = @StartDate, @UserId = @UserId;

        -- 4. shipping details on the containers (only the values that change; the ports only when empty)
        IF @UpdateContainers = 1
        BEGIN
            SET @MovementNo = (SELECT MovementNo FROM logistics.Movements WHERE Id = @MovementId);

            UPDATE c
            SET VesselName = v.VesselName, VoyageNo = v.VoyageNo, ShippingLine = v.ShippingLine, Eta = v.Eta,
                PortOfLoadingId = v.PortOfLoadingId, PortOfDestinationId = v.PortOfDestinationId, TruckNo = v.TruckNo,
                BlNo = v.BlNo, BlDate = v.BlDate, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            OUTPUT inserted.Id,
                   LEFT(CONCAT_WS(N', ',
                        CASE WHEN ISNULL(inserted.VesselName, N'') <> ISNULL(deleted.VesselName, N'') THEN N'vessel ' + inserted.VesselName END,
                        CASE WHEN ISNULL(inserted.VoyageNo, N'') <> ISNULL(deleted.VoyageNo, N'') THEN N'voyage ' + inserted.VoyageNo END,
                        CASE WHEN ISNULL(inserted.ShippingLine, N'') <> ISNULL(deleted.ShippingLine, N'') THEN N'shipping line ' + inserted.ShippingLine END,
                        CASE WHEN ISNULL(inserted.Eta, '19000101') <> ISNULL(deleted.Eta, '19000101') THEN N'ETA ' + CONVERT(NVARCHAR(10), inserted.Eta, 23) END,
                        CASE WHEN ISNULL(inserted.PortOfLoadingId, 0) <> ISNULL(deleted.PortOfLoadingId, 0) THEN N'port of loading' END,
                        CASE WHEN ISNULL(inserted.PortOfDestinationId, 0) <> ISNULL(deleted.PortOfDestinationId, 0) THEN N'port of destination' END,
                        CASE WHEN ISNULL(inserted.TruckNo, N'') <> ISNULL(deleted.TruckNo, N'') THEN N'truck ' + inserted.TruckNo END,
                        CASE WHEN ISNULL(inserted.BlNo, N'') <> ISNULL(deleted.BlNo, N'') THEN N'B/L ' + inserted.BlNo END,
                        CASE WHEN ISNULL(inserted.BlDate, '19000101') <> ISNULL(deleted.BlDate, '19000101') THEN N'B/L date ' + CONVERT(NVARCHAR(10), inserted.BlDate, 23) END), 450)
            INTO @Changed (ContainerId, Details)
            FROM logistics.Containers c
            INNER JOIN @Ids x ON x.Id = c.Id
            CROSS APPLY (SELECT VesselName          = CASE WHEN @VesselLeg = 1 THEN ISNULL(@VehicleOrVessel, c.VesselName) ELSE c.VesselName END,
                                VoyageNo            = CASE WHEN @VesselLeg = 1 THEN ISNULL(@VoyageNo, c.VoyageNo) ELSE c.VoyageNo END,
                                ShippingLine        = CASE WHEN @VesselLeg = 1 THEN ISNULL(@CarrierName, c.ShippingLine) ELSE c.ShippingLine END,
                                Eta                 = CASE WHEN @VesselLeg = 1 THEN ISNULL(@Eta, c.Eta) ELSE c.Eta END,
                                PortOfLoadingId     = CASE WHEN @Stage = N'Sea' THEN ISNULL(c.PortOfLoadingId, @FromPlaceId) ELSE c.PortOfLoadingId END,
                                PortOfDestinationId = CASE WHEN @Stage = N'Sea' THEN ISNULL(c.PortOfDestinationId, @ToPlaceId) ELSE c.PortOfDestinationId END,
                                TruckNo             = CASE WHEN @RoadLeg = 1 AND @VehicleOrVessel IS NOT NULL THEN LEFT(@VehicleOrVessel, 30) ELSE c.TruckNo END,
                                BlNo                = ISNULL(@BlNo, c.BlNo),
                                BlDate              = ISNULL(@BlDate, c.BlDate)) v
            WHERE ISNULL(v.VesselName, N'') <> ISNULL(c.VesselName, N'') OR ISNULL(v.VoyageNo, N'') <> ISNULL(c.VoyageNo, N'')
               OR ISNULL(v.ShippingLine, N'') <> ISNULL(c.ShippingLine, N'') OR ISNULL(v.Eta, '19000101') <> ISNULL(c.Eta, '19000101')
               OR ISNULL(v.PortOfLoadingId, 0) <> ISNULL(c.PortOfLoadingId, 0) OR ISNULL(v.PortOfDestinationId, 0) <> ISNULL(c.PortOfDestinationId, 0)
               OR ISNULL(v.TruckNo, N'') <> ISNULL(c.TruckNo, N'') OR ISNULL(v.BlNo, N'') <> ISNULL(c.BlNo, N'')
               OR ISNULL(v.BlDate, '19000101') <> ISNULL(c.BlDate, '19000101');

            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            SELECT ContainerId, N'Updated', LEFT(N'Shipping details from ' + @MovementNo + N': ' + Details, 500), @UserId
            FROM @Changed WHERE Details <> N'';
        END

        SET @NewId = @MovementId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrNo INT = ERROR_NUMBER(), @ErrMsg NVARCHAR(2048) = ERROR_MESSAGE();
        IF @ErrNo >= 50000 AND @Ref IS NOT NULL
        BEGIN
            SET @ErrMsg = LEFT(@Ref + N': ' + @ErrMsg, 2048);
            THROW @ErrNo, @ErrMsg, 1;
        END;
        THROW;
    END CATCH

    SELECT m.Id, m.MovementNo, m.Status, m.StartDate, m.PlannedDate, m.Eta,
           ContainerCount = (SELECT COUNT(*) FROM logistics.MovementContainers mc WHERE mc.MovementId = m.Id),
           m.RowVersion
    FROM logistics.Movements m
    WHERE m.Id = @NewId;
END

GO

