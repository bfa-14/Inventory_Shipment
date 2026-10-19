/* ================================================================== 7. A new leg for a group of containers */

-- Built (81) from the body of usp_Movement_ShipContainers (80), which stays as it is for its callers. The new leg of the
-- "Next step..." dialogs, for one container or a group:
--   - it leaves from where the containers are: an empty From is the place they are all at (a container that never moved:
--     its port of loading); a From elsewhere is refused by Save (70015) as before;
--   - a stay (Port, Customs, Border) happens at one place: To = From, whatever was sent; a Loading at the supplier ends at
--     the containers' port of loading when no To is sent; the Sea default "empty To = their port of destination" stays
--     for containers that never moved;
--   - @StartNow 1 starts it on @StartDate (Start's rules: never in the future, never before the previous leg ended -
--     70000, 70018), 0 plans it for @StartDate;
--   - @OnePerContainer 1 makes one movement per container (one truck each, each arriving on its own day), with the truck
--     no. (or vessel) and ETA of @PerContainer, else the leg's; 0 one movement for the group;
--   - drafts are confirmed only with @ConfirmDrafts (the API sends it only with containers.confirm), else refused by name;
--   - @UpdateContainers copies the vessel, voyage, B/L and ETA of a vessel leg (the ports only when empty) and the truck
--     no. of a road leg to the containers, as Start shipment does.
-- Every movement goes through usp_Movement_Save and usp_Movement_SetStatus: one movement at a time (70012), the place
-- rules (70015, 70016), the dates (70000, 70018). ALL OR NOTHING: one refusal undoes the whole group, and says which
-- container it was about. Returns one row per movement created (ContainerId: its container when one per container).
CREATE   PROCEDURE logistics.usp_Movement_AddLeg
    @ContainerIds     logistics.tvp_IdList READONLY,
    @MovementTypeId   INT            = NULL,   -- NULL = SEA
    @FromPlaceId      INT            = NULL,   -- NULL = where the containers are
    @ToPlaceId        INT            = NULL,   -- a stay: the From
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
    @ConfirmDrafts    BIT            = 0,
    @UpdateContainers BIT            = 1,
    @OnePerContainer  BIT            = 0,
    @PerContainer     logistics.tvp_LegContainer READONLY,   -- one per container: each container's truck no. and ETA
    @UserId           INT            = NULL
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
    SET @ConfirmDrafts = ISNULL(@ConfirmDrafts, 0);
    SET @UpdateContainers = ISNULL(@UpdateContainers, 1);
    SET @OnePerContainer = ISNULL(@OnePerContainer, 0);

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
    IF EXISTS (SELECT 1 FROM @PerContainer p WHERE NOT EXISTS (SELECT 1 FROM @Ids x WHERE x.Id = p.ContainerId))
        THROW 70000, 'A truck or ETA was given for a container that is not on this leg.', 1;

    DECLARE @Msg NVARCHAR(400);
    SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef
                        + CASE WHEN c.Status >= 6 THEN N' is already offloaded, closed or cancelled.'
                               ELSE N' is a draft: someone who may confirm containers must confirm it first.' END
    FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id
    WHERE c.Status >= 6 OR (c.Status = 1 AND @ConfirmDrafts = 0 AND @StartNow = 1)
    ORDER BY c.ContainerRef;
    IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

    -- A CONTAINER LEAVES FROM WHERE IT IS (80): the end of its latest movement, else (never moved) its port of loading.
    DECLARE @Places TABLE (ContainerId INT NOT NULL PRIMARY KEY, Moved BIT NOT NULL, PlaceId INT NULL);
    INSERT INTO @Places (ContainerId, Moved, PlaceId)
    SELECT x.Id, CASE WHEN p.PreviousMovementId IS NULL THEN 0 ELSE 1 END,
           CASE WHEN p.PreviousMovementId IS NULL THEN p.PortOfLoadingId ELSE p.PlaceId END
    FROM @Ids x
    INNER JOIN logistics.fn_ContainerPlaceForMovement(NULL) p ON p.ContainerId = x.Id;
    DECLARE @AnyMoved BIT = CASE WHEN EXISTS (SELECT 1 FROM @Places WHERE Moved = 1) THEN 1 ELSE 0 END;

    -- (81) Loading at the supplier: it leaves from the supplier (the From is chosen) and ends at their port of loading
    IF @Stage = N'Origin' AND @ToPlaceId IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id WHERE c.PortOfLoadingId IS NULL)
           OR (SELECT COUNT(DISTINCT c.PortOfLoadingId) FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id) > 1
            THROW 70000, 'Choose the To: the selected containers have no port of loading, or different ones.', 1;
        SELECT TOP (1) @ToPlaceId = c.PortOfLoadingId FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id;
    END
    IF @FromPlaceId IS NULL AND @Stage <> N'Origin'
    BEGIN
        IF EXISTS (SELECT 1 FROM @Places WHERE PlaceId IS NULL) OR (SELECT COUNT(DISTINCT PlaceId) FROM @Places) > 1
            THROW 70000, 'Choose the From: the selected containers are not all at the same place.', 1;
        SELECT TOP (1) @FromPlaceId = PlaceId FROM @Places;
    END
    IF @Stage = N'Sea' AND @ToPlaceId IS NULL AND @AnyMoved = 0
    BEGIN
        IF EXISTS (SELECT 1 FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id WHERE c.PortOfDestinationId IS NULL)
           OR (SELECT COUNT(DISTINCT c.PortOfDestinationId) FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id) > 1
            THROW 70000, 'Choose the destination port: the selected containers have no port of destination, or different ones.', 1;
        SELECT TOP (1) @ToPlaceId = c.PortOfDestinationId FROM @Ids x INNER JOIN logistics.Containers c ON c.Id = x.Id;
    END
    -- (81) A STAY (a port call, customs, a border crossing) HAPPENS AT ONE PLACE: To = From, whatever was sent
    IF @Stage IN (N'Port', N'Customs', N'Border') SET @ToPlaceId = @FromPlaceId;
    IF @FromPlaceId IS NULL OR @ToPlaceId IS NULL THROW 70000, 'Choose the departure and destination places.', 1;
    -- (81) A LEG THAT MOVES ENDS ELSEWHERE: a vessel or a truck from a place to itself is a To taken from a dialog that
    -- stood open while the containers moved on. A Delivery may end in the town it starts from (its warehouse), a
    -- transshipment changes vessel at one port, and a Loading at the supplier keeps its rule.
    IF @FromPlaceId = @ToPlaceId AND (@Stage = N'Sea' OR (@Stage = N'Transit' AND @TypeCode <> N'TRANSHIP'))
        THROW 70000, 'The departure and destination are the same place: choose the To.', 1;

    DECLARE @CarrierName NVARCHAR(100) = (SELECT LEFT(PartyName, 100) FROM masterdata.Parties WHERE Id = @CarrierPartyId);
    DECLARE @FromKind NVARCHAR(10) = (SELECT Kind FROM masterdata.Ports WHERE Id = @FromPlaceId),
            @ToKind   NVARCHAR(10) = (SELECT Kind FROM masterdata.Ports WHERE Id = @ToPlaceId);
    -- a vessel leg: sea freight, or a transshipment between two sea ports (feeder vessel, not inland transport);
    -- a road leg: the other legs that move (inland transport, border, delivery)
    DECLARE @VesselLeg BIT = CASE WHEN @Stage = N'Sea'
                                    OR (@Stage = N'Transit' AND @TypeCode <> N'INLAND' AND @FromKind = N'Sea' AND @ToKind = N'Sea')
                                  THEN 1 ELSE 0 END;
    DECLARE @RoadLeg BIT = CASE WHEN @VesselLeg = 0 AND @Stage IN (N'Transit', N'Border', N'Delivery') THEN 1 ELSE 0 END;
    DECLARE @MovementId INT, @Cid INT, @Ref NVARCHAR(30) = NULL, @LegVehicle NVARCHAR(100), @LegEta DATE;
    DECLARE @One logistics.tvp_IdList;
    DECLARE @Created TABLE (MovementId INT NOT NULL PRIMARY KEY, ContainerId INT NULL);
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

        -- 2. one movement for the group, or (81) one per container with its own truck and ETA; 3. started
        IF @OnePerContainer = 0
        BEGIN
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
            INSERT INTO @Created (MovementId, ContainerId) VALUES (@MovementId, NULL);
        END
        ELSE
        BEGIN
            DECLARE leg_cur CURSOR LOCAL STATIC READ_ONLY FORWARD_ONLY FOR
                SELECT c.Id, c.ContainerRef, COALESCE(p.VehicleOrVessel, @VehicleOrVessel), COALESCE(p.Eta, @Eta)
                FROM @Ids x
                INNER JOIN logistics.Containers c ON c.Id = x.Id
                LEFT JOIN @PerContainer p         ON p.ContainerId = x.Id
                ORDER BY LEN(c.ContainerRef), c.ContainerRef;
            OPEN leg_cur;
            FETCH NEXT FROM leg_cur INTO @Cid, @Ref, @LegVehicle, @LegEta;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @LegVehicle = NULLIF(LTRIM(RTRIM(@LegVehicle)), N'');
                DELETE FROM @One;
                INSERT INTO @One (Id) VALUES (@Cid);
                SET @MovementId = NULL;
                EXEC logistics.usp_Movement_Save
                     @MovementTypeId  = @MovementTypeId,
                     @FromPlaceId     = @FromPlaceId,
                     @ToPlaceId       = @ToPlaceId,
                     @PlannedDate     = @StartDate,
                     @Eta             = @LegEta,
                     @CarrierPartyId  = @CarrierPartyId,
                     @VehicleOrVessel = @LegVehicle,
                     @VoyageNo        = @VoyageNo,
                     @Reference       = @Reference,
                     @Notes           = @Notes,
                     @ContainerIds    = @One,
                     @UserId          = @UserId,
                     @NewId           = @MovementId OUTPUT;
                IF @StartNow = 1
                    EXEC logistics.usp_Movement_SetStatus @Id = @MovementId, @Action = N'Start', @Date = @StartDate, @UserId = @UserId;
                INSERT INTO @Created (MovementId, ContainerId) VALUES (@MovementId, @Cid);
                FETCH NEXT FROM leg_cur INTO @Cid, @Ref, @LegVehicle, @LegEta;
            END
            CLOSE leg_cur;
            DEALLOCATE leg_cur;
            SET @Ref = NULL;
        END

        -- 4. shipping details on the containers (only the values that change; the ports only when empty)
        IF @UpdateContainers = 1
        BEGIN
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
            LEFT JOIN @PerContainer p ON p.ContainerId = c.Id AND @OnePerContainer = 1
            CROSS APPLY (SELECT Vehicle = COALESCE(NULLIF(LTRIM(RTRIM(p.VehicleOrVessel)), N''), @VehicleOrVessel),
                                LegEta  = COALESCE(p.Eta, @Eta)) pc
            CROSS APPLY (SELECT VesselName          = CASE WHEN @VesselLeg = 1 THEN ISNULL(pc.Vehicle, c.VesselName) ELSE c.VesselName END,
                                VoyageNo            = CASE WHEN @VesselLeg = 1 THEN ISNULL(@VoyageNo, c.VoyageNo) ELSE c.VoyageNo END,
                                ShippingLine        = CASE WHEN @VesselLeg = 1 THEN ISNULL(@CarrierName, c.ShippingLine) ELSE c.ShippingLine END,
                                Eta                 = CASE WHEN @VesselLeg = 1 THEN ISNULL(pc.LegEta, c.Eta) ELSE c.Eta END,
                                PortOfLoadingId     = CASE WHEN @Stage = N'Sea' THEN ISNULL(c.PortOfLoadingId, @FromPlaceId) ELSE c.PortOfLoadingId END,
                                PortOfDestinationId = CASE WHEN @Stage = N'Sea' THEN ISNULL(c.PortOfDestinationId, @ToPlaceId) ELSE c.PortOfDestinationId END,
                                TruckNo             = CASE WHEN @RoadLeg = 1 AND pc.Vehicle IS NOT NULL THEN LEFT(pc.Vehicle, 30) ELSE c.TruckNo END,
                                BlNo                = ISNULL(@BlNo, c.BlNo),
                                BlDate              = ISNULL(@BlDate, c.BlDate)) v
            WHERE ISNULL(v.VesselName, N'') <> ISNULL(c.VesselName, N'') OR ISNULL(v.VoyageNo, N'') <> ISNULL(c.VoyageNo, N'')
               OR ISNULL(v.ShippingLine, N'') <> ISNULL(c.ShippingLine, N'') OR ISNULL(v.Eta, '19000101') <> ISNULL(c.Eta, '19000101')
               OR ISNULL(v.PortOfLoadingId, 0) <> ISNULL(c.PortOfLoadingId, 0) OR ISNULL(v.PortOfDestinationId, 0) <> ISNULL(c.PortOfDestinationId, 0)
               OR ISNULL(v.TruckNo, N'') <> ISNULL(c.TruckNo, N'') OR ISNULL(v.BlNo, N'') <> ISNULL(c.BlNo, N'')
               OR ISNULL(v.BlDate, '19000101') <> ISNULL(c.BlDate, '19000101');

            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            SELECT ch.ContainerId, N'Updated', LEFT(N'Shipping details from ' + m.MovementNo + N': ' + ch.Details, 500), @UserId
            FROM @Changed ch
            CROSS APPLY (SELECT TOP (1) mv.MovementNo
                         FROM @Created cr
                         INNER JOIN logistics.Movements mv ON mv.Id = cr.MovementId
                         WHERE cr.ContainerId IS NULL OR cr.ContainerId = ch.ContainerId
                         ORDER BY cr.MovementId) m
            WHERE ch.Details <> N'';
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrNo INT = ERROR_NUMBER(), @ErrMsg NVARCHAR(2048) = ERROR_MESSAGE();
        -- the container it was about, when the message does not name it already
        IF @ErrNo >= 50000 AND @Ref IS NOT NULL AND CHARINDEX(@Ref, @ErrMsg) = 0
        BEGIN
            SET @ErrMsg = LEFT(@Ref + N': ' + @ErrMsg, 2048);
            THROW @ErrNo, @ErrMsg, 1;
        END;
        THROW;
    END CATCH

    SELECT m.Id, m.MovementNo, m.Status, m.StartDate, m.PlannedDate, m.Eta,
           ContainerCount = (SELECT COUNT(*) FROM logistics.MovementContainers mc WHERE mc.MovementId = m.Id),
           cr.ContainerId, c.ContainerRef, m.RowVersion
    FROM @Created cr
    INNER JOIN logistics.Movements m  ON m.Id = cr.MovementId
    LEFT  JOIN logistics.Containers c ON c.Id = cr.ContainerId
    ORDER BY m.Id;
END

GO

