/* ================================================================== 4. Moving containers to a stage: what it does */

-- (111) ONE ROW PER ID ASKED (an unknown one too, Found 0). Action, when the container can go to the stage:
--   StartLeg              a Leg stage: the leg from where it stands
--   Complete              an Arrive stage, or an Offload stage reached by the leg it travels on: that leg is completed
--   CompleteThenDeliver   an Offload stage whose place its leg does not reach (Mokambo): completed, then the last leg
--   Deliver               an Offload stage, arrived elsewhere: the last leg, started and completed
--   Receive               an Offload stage, delivered there already: only its goods receipt
-- Reason says why it cannot (NULL when it can); AlreadyThere marks a container already at the stage (skipped, not
-- refused). The dates are the movement procedures' to judge (no future, never before the previous leg).
CREATE   PROCEDURE logistics.usp_ShipmentStage_Preview
    @StageId      INT,
    @ContainerIds logistics.tvp_IdList READONLY,
    @CanConfirm   BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Kind TINYINT, @FromId INT, @ToId INT, @Active BIT, @FromName NVARCHAR(100), @ToName NVARCHAR(100);
    SELECT @Kind = s.Kind, @FromId = s.FromPlaceId, @ToId = s.ToPlaceId, @Active = s.IsActive,
           @FromName = fp.PortName, @ToName = tp.PortName
    FROM logistics.ShipmentStages s
    LEFT JOIN masterdata.Ports fp ON fp.Id = s.FromPlaceId
    LEFT JOIN masterdata.Ports tp ON tp.Id = s.ToPlaceId
    WHERE s.Id = @StageId;
    IF @Kind IS NULL THROW 70006, 'Shipment stage not found.', 1;
    IF @Active = 0 THROW 70000, 'This stage is inactive: an administrator may turn it on again in Shipment Stages.', 1;

    SELECT ContainerId = x.Id,
           Found = CAST(CASE WHEN c.Id IS NULL THEN 0 ELSE 1 END AS BIT),
           c.ContainerRef, c.ContainerNo, ContainerStatus = c.Status,
           IsDraft = CAST(CASE WHEN c.Status = 1 THEN 1 ELSE 0 END AS BIT),
           CurrentStageId = st.StageId, CurrentStageName = st.StageName,
           Action = CASE WHEN r.Reason IS NULL THEN a.Action END,
           CanMove = CAST(CASE WHEN r.Reason IS NULL THEN 1 ELSE 0 END AS BIT),
           AlreadyThere = t.AlreadyThere,
           r.Reason,
           MovementId = st.ActiveMovementId, MovementNo = st.ActiveMovementNo,
           MovementContainerCount = (SELECT COUNT(*) FROM logistics.MovementContainers mc WHERE mc.MovementId = st.ActiveMovementId),
           st.PlaceId, PlaceName = pp.PortName,
           WarehouseCode = w.WarehouseCode,
           ReceiveWarning = CASE WHEN @Kind = 3 AND r.Reason IS NULL AND c.WarehouseId IS NULL
                                 THEN N'No warehouse on the container: its goods receipt will wait for one.' END
    FROM @ContainerIds x
    LEFT JOIN logistics.Containers c ON c.Id = x.Id
    OUTER APPLY logistics.fn_Container_Stage(c.Id) st
    LEFT JOIN masterdata.Ports pp ON pp.Id = st.PlaceId
    LEFT JOIN masterdata.Ports ap ON ap.Id = st.ActiveToPlaceId
    LEFT JOIN masterdata.Warehouses w ON w.Id = c.WarehouseId
    CROSS APPLY (SELECT AlreadyThere = CAST(CASE WHEN c.Status <> 8
                                                  AND ((st.StageId = @StageId AND st.ReceiptPending = 0)
                                                       OR (@Kind = 3 AND c.Status IN (6, 7))) THEN 1 ELSE 0 END AS BIT)) t
    CROSS APPLY (SELECT Action = CAST(CASE @Kind
                     WHEN 1 THEN N'StartLeg'
                     WHEN 2 THEN N'Complete'
                     ELSE CASE WHEN st.ActiveMovementId IS NOT NULL
                               THEN CASE WHEN st.ActiveToPlaceId = @ToId THEN N'Complete' ELSE N'CompleteThenDeliver' END
                               WHEN st.LastLegToPlaceId = @ToId THEN N'Receive'
                               ELSE N'Deliver' END END AS NVARCHAR(20))) a
    CROSS APPLY (SELECT Reason = CAST(CASE
                     WHEN c.Id IS NULL THEN N'Container not found.'
                     WHEN c.Status = 8 THEN N'It is cancelled.'
                     WHEN t.AlreadyThere = 1 THEN N'Already at this stage.'
                     WHEN c.Status IN (6, 7) THEN N'Its goods are received: its journey is over.'
                     -- a Leg stage
                     WHEN @Kind = 1 AND st.ActiveMovementId IS NOT NULL
                         THEN N'It is on its way (' + st.StageName + N', ' + st.ActiveMovementNo + N'): record its arrival first.'
                     WHEN @Kind = 1 AND st.ReceiptPending = 1
                         THEN N'It is delivered and waits for its goods receipt: choose ' + st.StageName + N'.'
                     WHEN @Kind = 1 AND @FromId IS NULL AND st.MovementCount > 0 THEN N'It has already left its port of loading.'
                     WHEN @Kind = 1 AND @FromId IS NULL AND c.PortOfLoadingId IS NULL
                         THEN N'It has no port of loading: set it on the container first.'
                     WHEN @Kind = 1 AND @FromId IS NOT NULL AND st.MovementCount = 0
                         THEN N'It is not dispatched yet: it leaves from ' + @FromName + N' only after it got there.'
                     WHEN @Kind = 1 AND @FromId IS NOT NULL AND ISNULL(st.PlaceId, -1) <> @FromId
                         THEN N'It is at ' + ISNULL(pp.PortName, N'another place') + N', not at ' + @FromName + N'.'
                     WHEN @Kind = 1 AND c.Status = 1 AND @CanConfirm = 0
                         THEN N'It is a draft: someone who may confirm containers must confirm it first.'
                     -- an Arrive stage
                     WHEN @Kind = 2 AND st.MovementCount = 0 THEN N'It is not dispatched yet.'
                     WHEN @Kind = 2 AND st.ActiveMovementId IS NULL
                         THEN N'It is not on its way to ' + @ToName + N': it is at ' + ISNULL(pp.PortName, N'another place') + N'.'
                     WHEN @Kind = 2 AND st.ActiveToPlaceId <> @ToId
                         THEN N'It is on its way to ' + ISNULL(ap.PortName, N'another place') + N', not to ' + @ToName + N'.'
                     -- an Offload stage
                     WHEN @Kind = 3 AND st.MovementCount = 0 THEN N'It is not dispatched yet.'
                     END AS NVARCHAR(400))) r
    ORDER BY c.ContainerRef, x.Id;
END