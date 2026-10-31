SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 81: LOGISTICS - THE NEXT STEP OF A CONTAINER (shipment, phase 2)

   The owner's words: "in the containers the shipment is not flexible for the user, I cannot start the shipment of a
   specific container in the containers page or any other place; make shipment more user friendly and flexible."

   Phase 2 of the container-first design: one "Next step..." for one container or 300, already filled in. The server
   says what each container's next step is, proposes its next leg (the usual one from where it is, else the stage
   order), groups many containers by step, and records a new leg for a group - one movement, or one per container
   (one truck each). Movements stay the only record: a new leg still goes through usp_Movement_Save and
   usp_Movement_SetStatus, so every phase 1 rule holds (70012 one movement at a time, 70015 / 70016 the place rules,
   70018 not before the previous leg ended, no date in the future), and a Complete still goes through the API, which
   drafts the goods receipts of a completed Delivery after the commit (script 79's switch included).

     1. Two indexes (a container's movements; the movements leaving a place) and the table type tvp_LegContainer (the
        truck no. and ETA of each container of a leg made "one per container").
     1b. NEW logistics.fn_Container_PreviousMovement (the previous movement of one container) and
        logistics.fn_Movement_StartBlock (why a planned movement cannot start yet, 80) re-created to read it: the same
        checks and messages, each container read for itself. Taken with a movement from a row, as the lists and the next
        step do, the place functions were worked out for every container of the database first: 0.6 s per planned
        movement on 50,000 containers, minutes for a Containers list holding planned legs.
     2. NEW logistics.fn_Container_NextStepKind: the step of a container, from what it already knows (fn_Container_ShipState,
        fn_Container_ReceivedBy, fn_Container_LastDelivery), the first that applies:
          Done          received, closed or cancelled: "Received into {warehouse}: the journey is over." /
                        "This container is cancelled."
          Complete      a movement in progress carries it ("Arrived at {To}...", "Cleared customs at {place}...")
          OpenReceipt   a draft goods receipt waits ("Open goods receipt (draft)")
          StartPlanned  its next planned movement waits ("Start {type}..."), with the refusal Start would give
          Ship          it never moved ("Start shipment...")
          Receive       its last leg is a completed Delivery and nothing received it yet ("Receive goods...")
          NextLeg       its last leg is completed ("Inland transport to Kasumbalesa...")
     3. NEW logistics.fn_Movement_NextLegHistory: the usual next leg from a place - the most frequent (type, To) of the
        movements of the last 365 days, not cancelled, that left this place after a leg of the same stage (for a container
        that never moved: its first leg), seen at least twice. Never a Loading at the supplier, an inactive type or place.
     4. NEW logistics.fn_Container_NextLegProposal: the leg proposed to one container, from that history, else from its
        own ports (never moved: Sea freight, port of loading -> port of destination), else from the stage order:
          after a Sea or Port leg      Inland transport from here, To to choose
          at a border or inland place  Customs clearance there (after a Transit or Border leg)
          after Customs (Cleared)      Warehouse delivery to the container's final destination (To to choose without one)
        A stay (Port, Customs, Border) takes To = the place. A Delivery proposed by history goes to the container's own
        final destination when it has one. Where it came from: History {n} / Ports / Stages / None.
     5. NEW logistics.fn_Container_NextStep: all of it for one container - the step, the movement it concerns (its
        RowVersion, dates, how many containers it carries), the proposed next leg, and for a movement to complete the leg
        proposed after it ("Then start Customs clearance at Kasumbalesa on the same day", ticked by default for a stay
        at the arrival place or after Customs / Border; none when its next leg is already planned: that planned
        movement is its next step).
     6. NEW logistics.usp_Container_NextStepPreview: the same for a list of containers (one call for 1,000 or more), the
        suggestion worked out once per (place, last stage), the containers grouped by (step, movement, type, From, To),
        and the ones that cannot move on, grouped by reason.
     7. NEW logistics.usp_Movement_AddLeg: a new leg for a group of containers, from where they are, "Start now" or
        "Plan only", one movement for the group or one per container (each with its own truck no. and ETA), drafts
        confirmed only when allowed; a vessel or truck leg from a place to itself is refused (70000). Built from the
        body of usp_Movement_ShipContainers, which stays as it is.
     8. logistics.usp_Container_Search: + the next step of each row and a @NextStep filter ("Start shipment", "Start
        planned leg", "Arrival due", "Next leg to plan", "Receive goods"): the logistics to-do list. The page is found
        first (the filters and the order of before), then its figures and its proposed legs for its rows only: 9.5 s a
        page on 50,000 containers before, every container's figures were worked out before the OFFSET.
     9. logistics.usp_Container_Get: + the next step on the header (set 1).
    10. logistics.usp_Movement_SetStatus: cancelling a movement that is not the last leg of one of its containers is
        refused (70010): "MOV-2026-000046 is not the last leg of KTG-2026-0031: cancel MOV-2026-000051 first." It
        silently broke the chain of places: the later leg left from a place the container never reached. A planned
        leg that a later leg already passed (started or completed after it) is no part of the chain: it may be cancelled.
        Start reads
        each container's previous leg for itself (70016, 70018 unchanged): 18 s a Start on 50,000 containers before.

   Re-created from their current bodies: logistics.fn_Movement_StartBlock (80), logistics.usp_Container_Search (80),
   logistics.usp_Container_Get (80), logistics.usp_Movement_SetStatus (80).
   New: logistics.fn_Container_PreviousMovement, logistics.fn_Container_NextStepKind, logistics.fn_Movement_NextLegHistory, logistics.fn_Container_NextLegProposal,
   logistics.fn_Container_NextStep, logistics.usp_Container_NextStepPreview, logistics.usp_Movement_AddLeg, the type
   logistics.tvp_LegContainer, the indexes IX_MovementContainers_ContainerMovement and IX_Movements_FromPlace.
   No new error number: 70010 for the cancel rule; usp_Movement_AddLeg raises the errors of Save, Start and Confirm.

   Requires script 80 (Schema.sql runs it first). Idempotent, additive: re-applied at every API start-up, and builds a
   brand-new empty database (the type and the indexes come before the procedures that use them).
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'logistics.fn_Container_ShipState') IS NULL                       -- 80
   OR OBJECT_ID(N'logistics.fn_Movement_StartBlock') IS NULL                     -- 80
   OR OBJECT_ID(N'logistics.usp_Movement_JoinCandidates', N'P') IS NULL          -- 80
    THROW 70000, 'Script 81 requires script 80: apply it first.', 1;
GO

/* ================================================================== 1. Indexes and the table type */

-- A CONTAINER'S MOVEMENTS: every step, place and history lookup goes from a container to its movements (the latest, the
-- one in progress, the previous one). IX_MovementContainers_Container holds the container only, so each row cost a key
-- lookup for its MovementId; on 50,000 containers the list paid it hundreds of thousands of times.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_MovementContainers_ContainerMovement' AND object_id = OBJECT_ID(N'logistics.MovementContainers'))
    CREATE NONCLUSTERED INDEX IX_MovementContainers_ContainerMovement ON logistics.MovementContainers (ContainerId, MovementId);
GO

-- THE MOVEMENTS LEAVING A PLACE: the usual next leg from it (fn_Movement_NextLegHistory).
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Movements_FromPlace' AND object_id = OBJECT_ID(N'logistics.Movements'))
    CREATE NONCLUSTERED INDEX IX_Movements_FromPlace ON logistics.Movements (FromPlaceId, Status)
        INCLUDE (MovementTypeId, ToPlaceId, PlannedDate, StartDate, CreatedAtUtc);
GO

-- One row per container of a leg made "one per container": its own truck (or vessel) and ETA, else the leg's.
IF TYPE_ID(N'logistics.tvp_LegContainer') IS NULL
    CREATE TYPE logistics.tvp_LegContainer AS TABLE
    (
        ContainerId     INT           NOT NULL PRIMARY KEY,
        VehicleOrVessel NVARCHAR(100) NULL,
        Eta             DATE          NULL
    );
GO

/* ================================================================== 1b. A planned movement's refusal, fast on any number of containers */

-- THE PREVIOUS MOVEMENT OF ONE CONTAINER before @MovementId (NULL = its latest): its movement not cancelled with the
-- highest Id below - the "previous" of fn_ContainerPlaceForMovement, read for one container only (the index on
-- (ContainerId, MovementId)). At most one row.
CREATE OR ALTER FUNCTION logistics.fn_Container_PreviousMovement (@ContainerId INT, @MovementId INT)
RETURNS TABLE
AS
RETURN
SELECT TOP (1) m.Id, m.MovementNo, m.Status, m.MovementTypeId, m.FromPlaceId, m.ToPlaceId, m.StartDate, m.EndDate
FROM logistics.MovementContainers mc
INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
WHERE mc.ContainerId = @ContainerId AND m.Status <> 4 AND (@MovementId IS NULL OR mc.MovementId < @MovementId)
ORDER BY mc.MovementId DESC;
GO

-- Re-created (81) from the body of script 80: the same checks and messages, each container's previous movement and fit
-- read for THAT container (fn_Container_PreviousMovement; the container inside the APPLY of fn_ContainerFitForMovement).
-- Taken with a movement from a row (fn_Container_ShipState, the lists, the next step), the functions over every
-- container (fn_ContainerPlaceForMovement, fn_ContainerFitForMovement) were worked out for all the containers and
-- completed movements of the database before the join kept the movement's own: 0.6 s per planned movement on 50,000
-- containers, minutes for a list holding planned legs. Nothing else changes.
CREATE OR ALTER FUNCTION logistics.fn_Movement_StartBlock (@MovementId INT)
RETURNS TABLE
AS
RETURN
SELECT m.Id AS MovementId,
       Reason = CAST(CASE WHEN m.Status = 1 THEN COALESCE(
           CASE WHEN NOT EXISTS (SELECT 1 FROM logistics.MovementContainers x WHERE x.MovementId = m.Id)
                THEN N'Tick at least one container before starting.' END,
           (SELECT TOP (1) N'Container ' + c.ContainerRef + CASE WHEN c.Status = 1 THEN N' is not confirmed yet.'
                                                                 ELSE N' is already offloaded, closed or cancelled.' END
            FROM logistics.MovementContainers mc
            INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
            WHERE mc.MovementId = m.Id AND (c.Status = 1 OR c.Status >= 6)
            ORDER BY c.ContainerRef),
           (SELECT TOP (1) N'Container ' + c.ContainerRef + N' is already travelling with movement ' + o.MovementNo + N'. Complete it first.'
            FROM logistics.MovementContainers mc
            INNER JOIN logistics.Containers c          ON c.Id = mc.ContainerId
            INNER JOIN logistics.MovementContainers oc ON oc.ContainerId = mc.ContainerId AND oc.MovementId <> m.Id
            INNER JOIN logistics.Movements o           ON o.Id = oc.MovementId AND o.Status = 2
            WHERE mc.MovementId = m.Id
            ORDER BY c.ContainerRef),
           (SELECT TOP (1) N'Container ' + c.ContainerRef + N': the previous movement ' + pm.MovementNo + N' (' + pf.PortName
                           + N' ' + NCHAR(8594) + N' ' + pt.PortName + N') is not completed yet.'
            FROM logistics.MovementContainers mc
            INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
            CROSS APPLY logistics.fn_Container_PreviousMovement(mc.ContainerId, m.Id) pm             -- (81)
            INNER JOIN masterdata.Ports pf    ON pf.Id = pm.FromPlaceId
            INNER JOIN masterdata.Ports pt    ON pt.Id = pm.ToPlaceId
            WHERE mc.MovementId = m.Id AND pm.Status <> 3
            ORDER BY c.ContainerRef),
           (SELECT TOP (1) N'Container ' + c.ContainerRef + N' cannot leave from ' + f.PortName + N'. ' + p.Reason
            FROM logistics.MovementContainers mc
            INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
            CROSS APPLY (SELECT x.* FROM logistics.fn_ContainerFitForMovement(m.Id, m.FromPlaceId, m.ToPlaceId, m.MovementTypeId) x
                         WHERE x.ContainerId = mc.ContainerId) p                                                   -- (81)
            INNER JOIN masterdata.Ports f     ON f.Id = m.FromPlaceId
            WHERE mc.MovementId = m.Id AND p.Fits = 0
            ORDER BY c.ContainerRef)) END AS NVARCHAR(400)),
       StartNotBefore = nb.EndDate, StartNotBeforeMovementNo = nb.MovementNo, StartNotBeforePlaceName = nb.PlaceName
FROM logistics.Movements m
OUTER APPLY (SELECT TOP (1) pm.EndDate, pm.MovementNo, PlaceName = tp.PortName
             FROM logistics.MovementContainers mc
             CROSS APPLY logistics.fn_Container_PreviousMovement(mc.ContainerId, m.Id) pm            -- (81)
             INNER JOIN masterdata.Ports tp    ON tp.Id = pm.ToPlaceId
             WHERE mc.MovementId = m.Id AND pm.Status = 3 AND pm.EndDate IS NOT NULL
             ORDER BY pm.EndDate DESC, pm.Id DESC) nb
WHERE m.Id = @MovementId AND m.Status IN (1, 2);
GO

/* ================================================================== 2. The step of a container */

-- One row: the next step of a container from what the caller already read of it (the list reads it for every row, so
-- nothing is read twice): its status, its ship state (fn_Container_ShipState), its latest completed Delivery
-- (fn_Container_LastDelivery) and its open goods receipt (fn_Container_ReceivedBy). The first that applies:
-- Done, Complete, OpenReceipt, StartPlanned, Ship, Receive, NextLeg (see the header). BlockedReason: why it cannot be
-- taken at all (the journey is over; a draft or the planned movement's own refusal on StartPlanned). The rights
-- (containers.movements.manage, containers.confirm for a draft, the goods receipt rights) are the caller's to check.
CREATE OR ALTER FUNCTION logistics.fn_Container_NextStepKind
(
    @ContainerId            INT,
    @Status                 TINYINT,
    @MovementCount          INT,
    @ActiveMovementId       INT,
    @PlannedMovementId      INT,
    @PlannedBlockedReason   NVARCHAR(400),
    @LastMovementId         INT,
    @LastDeliveryMovementId INT,
    @GoodsReceiptStatus     TINYINT
)
RETURNS TABLE
AS
RETURN
SELECT Kind = CAST(CASE WHEN @Status >= 6 THEN N'Done'
                        WHEN @ActiveMovementId IS NOT NULL THEN N'Complete'
                        WHEN @GoodsReceiptStatus = 1 THEN N'OpenReceipt'
                        WHEN @PlannedMovementId IS NOT NULL THEN N'StartPlanned'
                        WHEN ISNULL(@MovementCount, 0) = 0 THEN N'Ship'
                        WHEN @LastDeliveryMovementId = @LastMovementId THEN N'Receive'
                        ELSE N'NextLeg' END AS NVARCHAR(12)),
       BlockedReason = CAST(CASE
            WHEN @Status = 8 THEN N'This container is cancelled.'
            WHEN @Status IN (6, 7)
                 -- where it was received: its posted goods receipt, else (an offload of before) its own warehouse
                 THEN ISNULL(N'Received into ' + (SELECT TOP (1) COALESCE(gw.WarehouseName, cw.WarehouseName)
                                                  FROM logistics.Containers c
                                                  LEFT JOIN masterdata.Warehouses cw ON cw.Id = c.WarehouseId
                                                  OUTER APPLY (SELECT TOP (1) w.WarehouseName
                                                               FROM purchase.GoodsReceipts g
                                                               INNER JOIN masterdata.Warehouses w ON w.Id = g.WarehouseId
                                                               WHERE g.ContainerId = c.Id AND g.Status = 2
                                                               ORDER BY g.Id DESC) gw
                                                  WHERE c.Id = @ContainerId) + N': the journey is over.',
                             CASE WHEN @Status = 7 THEN N'This container is closed: its journey is over.'
                                  ELSE N'This container is received: its journey is over.' END)
            WHEN @ActiveMovementId IS NOT NULL OR @GoodsReceiptStatus = 1 THEN NULL
            WHEN @PlannedMovementId IS NOT NULL AND @Status = 1 THEN N'Confirm the container first: a draft cannot start a movement.'
            WHEN @PlannedMovementId IS NOT NULL THEN @PlannedBlockedReason END AS NVARCHAR(400));
GO

/* ================================================================== 3. The usual next leg from a place */

-- At most one row: the next leg most often taken from @PlaceId by the containers whose previous leg (the movement not
-- cancelled with the highest Id below, as everywhere) had the stage @LastStage and ended there - with @LastStage NULL,
-- the first leg of containers that never moved before. Movements of the last 365 days (start, else planned, else created),
-- planned, in progress or completed, counted once each however many containers they carry; seen at least twice; ties
-- go to the most recent. A Loading at the supplier is never proposed (it is only for containers that never moved and
-- leaves from the supplier, not from here), nor an inactive type or place.
-- WORKED OUT ONCE PER (place, last stage): usp_Container_NextStepPreview and the list call it per group, not per row.
CREATE OR ALTER FUNCTION logistics.fn_Movement_NextLegHistory (@PlaceId INT, @LastStage NVARCHAR(10))
RETURNS TABLE
AS
RETURN
SELECT TOP (1) m.MovementTypeId, m.ToPlaceId, Legs = COUNT(*)
FROM logistics.Movements m
INNER JOIN masterdata.MovementTypes t ON t.Id = m.MovementTypeId AND t.IsActive = 1 AND t.Stage <> N'Origin'
INNER JOIN masterdata.Ports tp        ON tp.Id = m.ToPlaceId AND tp.IsActive = 1
WHERE m.FromPlaceId = @PlaceId
  AND m.Status IN (1, 2, 3)
  AND COALESCE(m.StartDate, m.PlannedDate, CAST(m.CreatedAtUtc AS DATE)) >= DATEADD(DAY, -365, CAST(SYSUTCDATETIME() AS DATE))
  AND EXISTS (SELECT 1
              FROM logistics.MovementContainers mc
              OUTER APPLY (SELECT TOP (1) pm.ToPlaceId, pt.Stage
                           FROM logistics.MovementContainers pc
                           INNER JOIN logistics.Movements pm      ON pm.Id = pc.MovementId
                           INNER JOIN masterdata.MovementTypes pt ON pt.Id = pm.MovementTypeId
                           WHERE pc.ContainerId = mc.ContainerId AND pm.Status <> 4 AND pm.Id < m.Id
                           ORDER BY pm.Id DESC) pv
              WHERE mc.MovementId = m.Id
                AND ((@LastStage IS NULL AND pv.Stage IS NULL)
                     OR (pv.Stage = @LastStage AND pv.ToPlaceId = @PlaceId)))
GROUP BY m.MovementTypeId, m.ToPlaceId
HAVING COUNT(*) >= 2
ORDER BY COUNT(*) DESC, MAX(m.Id) DESC;
GO

/* ================================================================== 4. The leg proposed to a container */

-- At most one row: the next leg proposed to a container at @PlaceId (its place: the end of its latest movement, its port
-- of loading when it never moved) whose last leg had the stage @LastStage (NULL = never moved), @IsCleared once it
-- cleared customs, with the history of its (place, last stage) worked out by the caller (fn_Movement_NextLegHistory:
-- @HistTypeId, @HistToPlaceId, @HistLegs). None after a Delivery: its goods are received next.
--   1. Never moved, with a port of destination: Sea freight from the port of loading to it ("Ports"). The container
--      says where it goes: its own ports come before the history of other containers.
--   2. The history (fn_Movement_NextLegHistory): "History", {n} earlier legs. A Delivery goes to the container's own
--      final destination when it has one ("Ports" when that is not the usual To).
--   3. The stage order ("Stages"): never moved without a port of destination -> Sea freight, To to choose; after a
--      Loading at the supplier -> Sea freight to the port of destination; cleared (or after Customs) -> Warehouse
--      delivery to the final destination; after a Sea or Port leg -> Inland transport, To to choose; after a Transit
--      or Border leg -> Customs clearance at a border or inland place, Inland transport at a sea port (a transshipment).
--   The type of a stage is the active one with the usual code (SEA, INLAND, CUSTOMS, DELIVERY), else the first by sort
--   order: never an id. A stay (Port, Customs, Border) takes To = the place; an inactive place is never proposed (To to
--   choose). Source "None" when the stage's types are all inactive: the type is then left to choose ("Choose the type"),
--   the container still moves on (usp_Container_NextStepPreview blocks it only when no movement type is active at all).
-- OnePerContainer: the default of the bulk dialog - one movement for the group for a vessel or a stay at the port
-- (Sea, Port, a transshipment, Origin), one per container for a truck (Inland transport, Border, Customs, Delivery):
-- each truck arrives on its own day.
CREATE OR ALTER FUNCTION logistics.fn_Container_NextLegProposal
(
    @ContainerId   INT,
    @PlaceId       INT,
    @LastStage     NVARCHAR(10),
    @IsCleared     BIT,
    @HistTypeId    INT,
    @HistToPlaceId INT,
    @HistLegs      INT
)
RETURNS TABLE
AS
RETURN
SELECT TypeId = t.Id, TypeCode = t.TypeCode, TypeName = t.TypeName, Stage = t.Stage,
       FromPlaceId = @PlaceId, FromName = fp.PortName,
       ToPlaceId = tp.Id, ToName = tp.PortName,
       Source = sr.Source,
       Legs = CASE WHEN sr.Source = N'History' THEN @HistLegs END,
       IsStay = CAST(CASE WHEN t.Stage IN (N'Port', N'Customs', N'Border') THEN 1 ELSE 0 END AS BIT),
       OnePerContainer = CAST(CASE WHEN t.Id IS NULL OR t.Stage IN (N'Sea', N'Port', N'Origin') OR t.TypeCode = N'TRANSHIP'
                                   THEN 0 ELSE 1 END AS BIT)
FROM logistics.Containers c
LEFT JOIN masterdata.Ports pk ON pk.Id = @PlaceId
LEFT JOIN masterdata.Ports fp ON fp.Id = @PlaceId
CROSS APPLY (SELECT Mode = CASE WHEN @LastStage IS NULL AND c.PortOfDestinationId IS NOT NULL THEN N'Ports'
                                WHEN @HistTypeId IS NOT NULL THEN N'History'
                                WHEN @LastStage IS NULL OR @LastStage = N'Origin' THEN N'Sea'
                                WHEN @IsCleared = 1 OR @LastStage = N'Customs' THEN N'Delivery'
                                WHEN @LastStage IN (N'Sea', N'Port') OR pk.Kind = N'Sea' THEN N'Inland'
                                ELSE N'Customs' END) m
CROSS APPLY (SELECT WantStage = CASE m.Mode WHEN N'Ports' THEN N'Sea' WHEN N'Sea' THEN N'Sea' WHEN N'Delivery' THEN N'Delivery'
                                            WHEN N'Inland' THEN N'Transit' WHEN N'Customs' THEN N'Customs' END,
                    WantCode  = CASE m.Mode WHEN N'Ports' THEN N'SEA' WHEN N'Sea' THEN N'SEA' WHEN N'Delivery' THEN N'DELIVERY'
                                            WHEN N'Inland' THEN N'INLAND' WHEN N'Customs' THEN N'CUSTOMS' END) w
OUTER APPLY (SELECT TOP (1) x.Id, x.TypeCode, x.TypeName, x.Stage
             FROM masterdata.MovementTypes x
             WHERE x.IsActive = 1
               AND ((m.Mode = N'History' AND x.Id = @HistTypeId) OR (m.Mode <> N'History' AND x.Stage = w.WantStage))
             ORDER BY CASE WHEN x.TypeCode = w.WantCode THEN 0 ELSE 1 END, x.SortOrder, x.Id) t
CROSS APPLY (SELECT Source = CAST(CASE WHEN t.Id IS NULL THEN N'None'
                                       WHEN m.Mode = N'History' AND t.Stage = N'Delivery' AND c.FinalDestinationId IS NOT NULL
                                            AND c.FinalDestinationId <> ISNULL(@HistToPlaceId, 0) THEN N'Ports'
                                       WHEN m.Mode = N'History' THEN N'History'
                                       WHEN m.Mode = N'Ports' OR (m.Mode = N'Sea' AND c.PortOfDestinationId IS NOT NULL) THEN N'Ports'
                                       ELSE N'Stages' END AS NVARCHAR(10))) sr
LEFT JOIN masterdata.Ports tp
       ON tp.IsActive = 1
      AND tp.Id = CASE WHEN t.Stage IN (N'Port', N'Customs', N'Border') THEN @PlaceId
                       WHEN m.Mode = N'History' AND t.Stage = N'Delivery' THEN ISNULL(c.FinalDestinationId, @HistToPlaceId)
                       WHEN m.Mode = N'History' THEN @HistToPlaceId
                       WHEN m.Mode IN (N'Ports', N'Sea') THEN c.PortOfDestinationId
                       WHEN m.Mode = N'Delivery' THEN c.FinalDestinationId END
WHERE c.Id = @ContainerId AND ISNULL(@LastStage, N'') <> N'Delivery';
GO

/* ================================================================== 5. The next step of one container */

-- One row per container (the container page, the dialog for one container): the step (fn_Container_NextStepKind), where
-- it is, the movement the step concerns (Complete: the one in progress; StartPlanned: the planned one) with its
-- RowVersion and dates, the proposed next leg (Ship, NextLeg) and, for a movement to complete, the leg proposed after it
-- (Then*, not after a Delivery). MovementNotBefore: the earliest date of the step (Complete: the movement's start;
-- StartPlanned: the end of the previous leg); for a new leg it is PlaceSince. ThenDefault: the "Then" box is ticked
-- by default when the next leg is a stay at the arrival place, or follows Customs or Border.
CREATE OR ALTER FUNCTION logistics.fn_Container_NextStep (@ContainerId INT)
RETURNS TABLE
AS
RETURN
SELECT c.Id AS ContainerId,
       Kind = k.Kind, BlockedReason = k.BlockedReason,
       IsDraft = CAST(CASE WHEN c.Status = 1 THEN 1 ELSE 0 END AS BIT),
       HasContainerNo = CAST(CASE WHEN NULLIF(LTRIM(RTRIM(c.ContainerNo)), N'') IS NULL THEN 0 ELSE 1 END AS BIT),
       -- the dates typed on a container followed without movements: its first leg replaces them (usp_Container_RefreshStatus)
       HasTypedDates = CAST(CASE WHEN ss.MovementCount = 0 AND (c.DispatchDate IS NOT NULL OR c.ActualPortArrival IS NOT NULL
                                                                 OR c.BorderCrossingDate IS NOT NULL OR c.CustomsReleaseDate IS NOT NULL)
                                 THEN 1 ELSE 0 END AS BIT),
       ss.MovementCount, ss.PlaceId, ss.PlaceName, PlaceKind = pk.Kind, ss.PlaceSince,
       LastStage = ls.Stage, ss.LastMovementId, ss.LastMovementNo, ss.LastMovementEndDate,
       MovementId = mv.Id, MovementNo = mv.MovementNo, MovementRowVersion = mv.RowVersion, MovementStatus = mv.Status,
       MovementTypeId = mv.MovementTypeId, MovementTypeCode = mv.TypeCode, MovementTypeName = mv.TypeName,
       MovementStage = mv.Stage, MovementFromPlaceId = mv.FromPlaceId, MovementFromName = mv.FromName,
       MovementToPlaceId = mv.ToPlaceId, MovementToName = mv.ToName,
       MovementPlannedDate = mv.PlannedDate, MovementStartDate = mv.StartDate, MovementEta = mv.Eta,
       MovementContainerCount = mv.Cnt,
       MovementNotBefore = CASE k.Kind WHEN N'Complete' THEN mv.StartDate WHEN N'StartPlanned' THEN ss.PlannedMovementNotBefore END,
       rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus,
       ProposedTypeId = pr.TypeId, ProposedTypeCode = pr.TypeCode, ProposedTypeName = pr.TypeName, ProposedStage = pr.Stage,
       ProposedFromPlaceId = pr.FromPlaceId, ProposedFromName = pr.FromName,
       ProposedToPlaceId = pr.ToPlaceId, ProposedToName = pr.ToName,
       ProposalSource = pr.Source, ProposalLegs = pr.Legs, ProposedIsStay = pr.IsStay,
       ProposedOnePerContainer = pr.OnePerContainer,
       ThenTypeId = tn.TypeId, ThenTypeCode = tn.TypeCode, ThenTypeName = tn.TypeName, ThenStage = tn.Stage,
       ThenFromPlaceId = tn.FromPlaceId, ThenFromName = tn.FromName, ThenToPlaceId = tn.ToPlaceId, ThenToName = tn.ToName,
       ThenSource = tn.Source, ThenLegs = tn.Legs, ThenIsStay = tn.IsStay,
       ThenDefault = CAST(CASE WHEN tn.TypeId IS NOT NULL AND (tn.IsStay = 1 OR mv.Stage IN (N'Customs', N'Border'))
                               THEN 1 ELSE 0 END AS BIT)
FROM logistics.Containers c
CROSS APPLY logistics.fn_Container_ShipState(c.Id) ss
CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl
CROSS APPLY logistics.fn_Container_NextStepKind(c.Id, c.Status, ss.MovementCount, ss.ActiveMovementId, ss.PlannedMovementId,
                                                ss.PlannedMovementBlockedReason, ss.LastMovementId, dl.MovementId,
                                                rb.GoodsReceiptStatus) k
LEFT JOIN masterdata.Ports pk ON pk.Id = ss.PlaceId
OUTER APPLY (SELECT lt.Stage
             FROM logistics.Movements lm
             INNER JOIN masterdata.MovementTypes lt ON lt.Id = lm.MovementTypeId
             WHERE lm.Id = ss.LastMovementId) ls
OUTER APPLY (SELECT m.Id, m.MovementNo, m.RowVersion, m.Status, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
                    m.FromPlaceId, FromName = fp.PortName, m.ToPlaceId, ToName = tp.PortName,
                    m.PlannedDate, m.StartDate, m.Eta,
                    Cnt = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = m.Id)
             FROM logistics.Movements m
             INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
             INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
             INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
             WHERE m.Id = CASE k.Kind WHEN N'Complete' THEN ss.ActiveMovementId WHEN N'StartPlanned' THEN ss.PlannedMovementId END) mv
-- the next leg: from where it is, after its last leg
OUTER APPLY (SELECT h.MovementTypeId, h.ToPlaceId, h.Legs
             FROM logistics.fn_Movement_NextLegHistory(ss.PlaceId, CASE WHEN ss.MovementCount = 0 THEN NULL ELSE ls.Stage END) h
             WHERE k.Kind IN (N'Ship', N'NextLeg')) h
OUTER APPLY (SELECT p.*
             FROM logistics.fn_Container_NextLegProposal(c.Id, ss.PlaceId, CASE WHEN ss.MovementCount = 0 THEN NULL ELSE ls.Stage END,
                                                         CASE WHEN c.Status = 5 THEN 1 ELSE 0 END,
                                                         h.MovementTypeId, h.ToPlaceId, h.Legs) p
             WHERE k.Kind IN (N'Ship', N'NextLeg')) pr
-- then: the leg after the movement it completes, from its To (a Customs completed makes it Cleared) - none when its next
-- leg is already planned: that planned movement is its next step, and a new leg would be refused (70016)
OUTER APPLY (SELECT h.MovementTypeId, h.ToPlaceId, h.Legs
             FROM logistics.fn_Movement_NextLegHistory(mv.ToPlaceId, mv.Stage) h
             WHERE k.Kind = N'Complete' AND ss.PlannedMovementId IS NULL) th
OUTER APPLY (SELECT p.*
             FROM logistics.fn_Container_NextLegProposal(c.Id, mv.ToPlaceId, mv.Stage,
                                                         CASE WHEN c.Status = 5 OR mv.Stage = N'Customs' THEN 1 ELSE 0 END,
                                                         th.MovementTypeId, th.ToPlaceId, th.Legs) p
             WHERE k.Kind = N'Complete' AND ss.PlannedMovementId IS NULL) tn
WHERE c.Id = @ContainerId;
GO

/* ================================================================== 6. The next step of many containers */

-- The "Next step..." dialog for ticked containers (and the one for one container: the same call with one id). One
-- set-based call for 1,000 containers or more; the suggestion of each (place, last stage) is worked out once.
-- @CanConfirm: the reader holds containers.confirm. Without it a draft that never moved cannot ship (usp_Movement_AddLeg
-- would refuse it by name): it goes to "Cannot move on".
-- Result sets:
--   1. one row per container asked for (an unknown id too: "Not found"): the columns of fn_Container_NextStep, plus
--      CanMove, BlockGroup (the "Cannot move on" heading it falls under), GroupKey (its group in set 2), the orders and
--      suppliers it carries, and the shipping details a new leg starts from (vessel, voyage, B/L, truck, ETA);
--   2. one row per group of containers that can move on, by (step, movement, type, From, To): what the step is, the
--      movement it concerns (or the proposed new leg), how many ticked containers it holds (and how many the movement
--      carries: completing it moves them all), the earliest date, how many are drafts / have no container no. / typed
--      dates, the orders and suppliers, the "Then" leg (when every container of the group has the same one), and the
--      default "One per container";
--   3. the containers that cannot move on, by BlockGroup, with how many and the first refs.
CREATE OR ALTER PROCEDURE logistics.usp_Container_NextStepPreview
    @ContainerIds logistics.tvp_IdList READONLY,
    @CanConfirm   BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET @CanConfirm = ISNULL(@CanConfirm, 1);

    -- A PROPOSAL MISSING IS NOT A BLOCK: when the usual type of the next stage is inactive the container still moves on,
    -- its type to choose ("Choose the type"). It cannot move on only when no movement type is active at all.
    DECLARE @AnyActiveType BIT = CASE WHEN EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE IsActive = 1 AND Stage <> N'Origin')
                                      THEN 1 ELSE 0 END;

    -- 1. the step of each container (the reads of fn_Container_NextStep, without its suggestion)
    CREATE TABLE #Step
    (
        ContainerId INT NOT NULL PRIMARY KEY, Found BIT NOT NULL, ContainerRef NVARCHAR(30) NULL, ContainerNo NVARCHAR(20) NULL,
        Status TINYINT NULL, Kind NVARCHAR(12) NULL, BlockedReason NVARCHAR(400) NULL,
        MovementCount INT NULL, PlaceId INT NULL, PlaceName NVARCHAR(100) NULL, PlaceKind NVARCHAR(10) NULL, PlaceSince DATE NULL,
        LastStage NVARCHAR(10) NULL, LastMovementId INT NULL, LastMovementNo NVARCHAR(30) NULL, LastMovementEndDate DATE NULL,
        MovementId INT NULL, PlannedNotBefore DATE NULL,
        ActiveMovementId INT NULL, PlannedMovementId INT NULL, LastDeliveryMovementId INT NULL,
        GoodsReceiptId INT NULL, GoodsReceiptNumber NVARCHAR(30) NULL, GoodsReceiptStatus TINYINT NULL,
        HistPlaceId INT NULL, HistStage NVARCHAR(10) NULL      -- the (place, last stage) of its suggestion
    );

    INSERT INTO #Step (ContainerId, Found, ContainerRef, ContainerNo, Status, Kind, BlockedReason, MovementCount, PlaceId, PlaceName,
                       PlaceKind, PlaceSince, LastStage, LastMovementId, LastMovementNo, LastMovementEndDate, MovementId,
                       PlannedNotBefore, ActiveMovementId, PlannedMovementId, LastDeliveryMovementId,
                       GoodsReceiptId, GoodsReceiptNumber, GoodsReceiptStatus, HistPlaceId, HistStage)
    SELECT x.Id, CASE WHEN c.Id IS NULL THEN 0 ELSE 1 END, c.ContainerRef, c.ContainerNo, c.Status, k.Kind, k.BlockedReason,
           ss.MovementCount, ss.PlaceId, ss.PlaceName, pk.Kind, ss.PlaceSince, ls.Stage, ss.LastMovementId, ss.LastMovementNo,
           ss.LastMovementEndDate,
           CASE k.Kind WHEN N'Complete' THEN ss.ActiveMovementId WHEN N'StartPlanned' THEN ss.PlannedMovementId END,
           NULL, ss.ActiveMovementId, ss.PlannedMovementId, dl.MovementId,
           rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus,
           CASE WHEN k.Kind IN (N'Ship', N'NextLeg') THEN ss.PlaceId END,
           CASE WHEN k.Kind = N'NextLeg' THEN ls.Stage END
    FROM @ContainerIds x
    LEFT JOIN logistics.Containers c ON c.Id = x.Id
    OUTER APPLY logistics.fn_Container_ShipState(c.Id) ss
    OUTER APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl
    OUTER APPLY logistics.fn_Container_NextStepKind(c.Id, c.Status, ss.MovementCount, ss.ActiveMovementId, ss.PlannedMovementId,
                                                    NULL, ss.LastMovementId, dl.MovementId, rb.GoodsReceiptStatus) k
    LEFT JOIN masterdata.Ports pk ON pk.Id = ss.PlaceId
    OUTER APPLY (SELECT lt.Stage
                 FROM logistics.Movements lm
                 INNER JOIN masterdata.MovementTypes lt ON lt.Id = lm.MovementTypeId
                 WHERE lm.Id = ss.LastMovementId) ls;

    -- the movement each step concerns (Complete, StartPlanned), once per movement
    SELECT m.Id, m.MovementNo, m.RowVersion, m.Status, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, FromName = fp.PortName, m.ToPlaceId, ToName = tp.PortName, m.PlannedDate, m.StartDate, m.Eta,
           Cnt = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = m.Id)
    INTO #Mov
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    WHERE m.Id IN (SELECT MovementId FROM #Step WHERE MovementId IS NOT NULL);

    -- why a planned movement cannot start yet, once per movement (read through each container it cost seconds), and
    -- the step's refusal with it (fn_Container_NextStepKind: a draft, or the movement's own refusal)
    SELECT b.MovementId, b.Reason, b.StartNotBefore
    INTO #Sb
    FROM (SELECT DISTINCT MovementId FROM #Step WHERE Kind = N'StartPlanned') p
    CROSS APPLY logistics.fn_Movement_StartBlock(p.MovementId) b;

    UPDATE s
    SET PlannedNotBefore = b.StartNotBefore,
        BlockedReason = k.BlockedReason
    FROM #Step s
    INNER JOIN #Sb b ON b.MovementId = s.MovementId
    CROSS APPLY logistics.fn_Container_NextStepKind(s.ContainerId, s.Status, s.MovementCount, s.ActiveMovementId,
                                                    s.PlannedMovementId, b.Reason, s.LastMovementId, s.LastDeliveryMovementId,
                                                    s.GoodsReceiptStatus) k
    WHERE s.Kind = N'StartPlanned';

    -- 2. THE SUGGESTION, ONCE PER (place, last stage): the next leg of a container from where it is, and the leg after a
    -- movement to complete from that movement's To (the "Then" box)
    SELECT g.PlaceId, g.LastStage, h.MovementTypeId, h.ToPlaceId, h.Legs
    INTO #Hist
    FROM (SELECT DISTINCT PlaceId = HistPlaceId, LastStage = HistStage FROM #Step WHERE HistPlaceId IS NOT NULL
          UNION
          SELECT DISTINCT mv.ToPlaceId, mv.Stage
          FROM #Step s INNER JOIN #Mov mv ON mv.Id = s.MovementId
          WHERE s.Kind = N'Complete' AND mv.Stage <> N'Delivery') g
    CROSS APPLY logistics.fn_Movement_NextLegHistory(g.PlaceId, g.LastStage) h;

    -- 3. every container with its proposal, its group and why it cannot move on
    SELECT s.ContainerId, s.Found, s.ContainerRef, s.ContainerNo, s.Status, s.Kind, s.BlockedReason,
           IsDraft = CAST(CASE WHEN s.Status = 1 THEN 1 ELSE 0 END AS BIT),
           HasContainerNo = CAST(CASE WHEN NULLIF(LTRIM(RTRIM(s.ContainerNo)), N'') IS NULL THEN 0 ELSE 1 END AS BIT),
           HasTypedDates = CAST(CASE WHEN s.MovementCount = 0 AND (c.DispatchDate IS NOT NULL OR c.ActualPortArrival IS NOT NULL
                                                                    OR c.BorderCrossingDate IS NOT NULL OR c.CustomsReleaseDate IS NOT NULL)
                                     THEN 1 ELSE 0 END AS BIT),
           s.MovementCount, s.PlaceId, s.PlaceName, s.PlaceKind, s.PlaceSince,
           s.LastStage, s.LastMovementId, s.LastMovementNo, s.LastMovementEndDate,
           MovementId = mv.Id, MovementNo = mv.MovementNo, MovementRowVersion = mv.RowVersion, MovementStatus = mv.Status,
           MovementTypeId = mv.MovementTypeId, MovementTypeCode = mv.TypeCode, MovementTypeName = mv.TypeName,
           MovementStage = mv.Stage, MovementFromPlaceId = mv.FromPlaceId, MovementFromName = mv.FromName,
           MovementToPlaceId = mv.ToPlaceId, MovementToName = mv.ToName,
           MovementPlannedDate = mv.PlannedDate, MovementStartDate = mv.StartDate, MovementEta = mv.Eta,
           MovementContainerCount = mv.Cnt,
           MovementNotBefore = CASE s.Kind WHEN N'Complete' THEN mv.StartDate WHEN N'StartPlanned' THEN s.PlannedNotBefore END,
           s.GoodsReceiptId, s.GoodsReceiptNumber, s.GoodsReceiptStatus,
           ProposedTypeId = pr.TypeId, ProposedTypeCode = pr.TypeCode, ProposedTypeName = pr.TypeName, ProposedStage = pr.Stage,
           ProposedFromPlaceId = pr.FromPlaceId, ProposedFromName = pr.FromName,
           ProposedToPlaceId = pr.ToPlaceId, ProposedToName = pr.ToName,
           ProposalSource = pr.Source, ProposalLegs = pr.Legs, ProposedIsStay = pr.IsStay,
           ProposedOnePerContainer = pr.OnePerContainer,
           ThenTypeId = tn.TypeId, ThenTypeCode = tn.TypeCode, ThenTypeName = tn.TypeName, ThenStage = tn.Stage,
           ThenFromPlaceId = tn.FromPlaceId, ThenFromName = tn.FromName, ThenToPlaceId = tn.ToPlaceId, ThenToName = tn.ToName,
           ThenSource = tn.Source, ThenLegs = tn.Legs, ThenIsStay = tn.IsStay,
           ThenDefault = CAST(CASE WHEN tn.TypeId IS NOT NULL AND (tn.IsStay = 1 OR mv.Stage IN (N'Customs', N'Border'))
                                   THEN 1 ELSE 0 END AS BIT),
           -- the shipping details a new leg starts from (Sea: vessel, voyage, B/L; a truck leg: the truck)
           c.VesselName, c.VoyageNo, c.ShippingLine, c.BlNo, c.BlDate, c.TruckNo, ContainerEta = c.Eta,
           OrderNumbers = CASE WHEN ISNULL(po.OrderCount, 0) = 0 THEN NULL
                               WHEN po.OrderCount = 1 THEN po.FirstOrder
                               ELSE po.FirstOrder + N' +' + CAST(po.OrderCount - 1 AS NVARCHAR(10)) END,
           SupplierNames = CASE WHEN ISNULL(po.SupplierCount, 0) = 0 THEN NULL
                                WHEN po.SupplierCount = 1 THEN po.FirstSupplier
                                ELSE po.FirstSupplier + N' +' + CAST(po.SupplierCount - 1 AS NVARCHAR(10)) END,
           b.BlockGroup,
           CanMove = CAST(CASE WHEN b.BlockGroup IS NULL THEN 1 ELSE 0 END AS BIT),
           -- (step, movement, type, From, To): containers at different places or bound elsewhere fall apart by themselves
           GroupKey = CASE WHEN b.BlockGroup IS NULL
                           THEN CONCAT(s.Kind, N'|', mv.Id, N'|', COALESCE(mv.MovementTypeId, pr.TypeId), N'|',
                                       COALESCE(mv.FromPlaceId, pr.FromPlaceId), N'|', COALESCE(mv.ToPlaceId, pr.ToPlaceId)) END
    INTO #Row
    FROM #Step s
    LEFT JOIN logistics.Containers c ON c.Id = s.ContainerId
    LEFT JOIN #Mov mv                ON mv.Id = s.MovementId
    LEFT JOIN #Hist h                ON s.Kind IN (N'Ship', N'NextLeg') AND h.PlaceId = s.HistPlaceId
                                    AND ISNULL(h.LastStage, N'') = ISNULL(s.HistStage, N'')
    LEFT JOIN #Hist th               ON s.Kind = N'Complete' AND s.PlannedMovementId IS NULL
                                    AND th.PlaceId = mv.ToPlaceId AND th.LastStage = mv.Stage
    OUTER APPLY (SELECT p.*
                 FROM logistics.fn_Container_NextLegProposal(s.ContainerId, s.PlaceId,
                                                             CASE WHEN s.MovementCount = 0 THEN NULL ELSE s.LastStage END,
                                                             CASE WHEN s.Status = 5 THEN 1 ELSE 0 END,
                                                             h.MovementTypeId, h.ToPlaceId, h.Legs) p
                 WHERE s.Kind IN (N'Ship', N'NextLeg')) pr
    OUTER APPLY (SELECT p.*
                 FROM logistics.fn_Container_NextLegProposal(s.ContainerId, mv.ToPlaceId, mv.Stage,
                                                             CASE WHEN s.Status = 5 OR mv.Stage = N'Customs' THEN 1 ELSE 0 END,
                                                             th.MovementTypeId, th.ToPlaceId, th.Legs) p
                 -- no "Then" when its next leg is already planned (fn_Container_NextStep)
                 WHERE s.Kind = N'Complete' AND s.PlannedMovementId IS NULL) tn
    OUTER APPLY (SELECT OrderCount = COUNT(DISTINCT cl.PurchaseOrderId), SupplierCount = COUNT(DISTINCT d.SupplierId),
                        FirstOrder = MIN(d.DocumentNumber), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = s.ContainerId) po
    CROSS APPLY (SELECT BlockGroup = CAST(CASE
                     WHEN s.Found = 0 THEN N'Not found'
                     WHEN s.Kind = N'Done' THEN N'Received, closed or cancelled'
                     -- a draft goods receipt waits: it is opened, not made again (Receive goods... refuses it, 63013)
                     WHEN s.Kind = N'OpenReceipt'
                         THEN N'A draft goods receipt waits: Open goods receipt (draft)'
                     WHEN s.Kind = N'Receive'
                         THEN N'Delivered: its goods are received next (Receive goods' + NCHAR(8230) + N')'
                     WHEN s.Kind = N'Ship' AND s.Status = 1 AND @CanConfirm = 0 THEN N'Draft - you may not confirm containers'
                     WHEN s.Kind IN (N'Ship', N'NextLeg') AND s.PlaceId IS NULL
                         THEN N'No port of loading: open the container to choose where it leaves from'
                     WHEN s.Kind IN (N'Ship', N'NextLeg') AND @AnyActiveType = 0
                         THEN N'No movement type is active: activate one in Master Data ' + NCHAR(8250) + N' Movement Types'
                     ELSE s.BlockedReason END AS NVARCHAR(400))) b;

    SELECT * FROM #Row ORDER BY CanMove DESC, GroupKey, LEN(ContainerRef), ContainerRef, ContainerId;

    -- 4. the groups (set 2), with the orders and suppliers of each, for information
    SELECT g.GroupKey, OrderCount = COUNT(DISTINCT cl.PurchaseOrderId), SupplierCount = COUNT(DISTINCT d.SupplierId),
           FirstOrder = MIN(d.DocumentNumber), FirstSupplier = MIN(sp.PartyName)
    INTO #GroupOrders
    FROM #Row g
    INNER JOIN logistics.ContainerLines cl  ON cl.ContainerId = g.ContainerId
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
    INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
    WHERE g.CanMove = 1
    GROUP BY g.GroupKey;

    SELECT r.GroupKey, Kind = MIN(r.Kind),
           MovementId = MIN(r.MovementId), MovementNo = MIN(r.MovementNo), MovementRowVersion = MAX(r.MovementRowVersion),
           MovementTypeId = MIN(COALESCE(r.MovementTypeId, r.ProposedTypeId)),
           MovementTypeCode = MIN(COALESCE(r.MovementTypeCode, r.ProposedTypeCode)),
           MovementTypeName = MIN(COALESCE(r.MovementTypeName, r.ProposedTypeName)),
           MovementStage = MIN(COALESCE(r.MovementStage, r.ProposedStage)),
           FromPlaceId = MIN(COALESCE(r.MovementFromPlaceId, r.ProposedFromPlaceId)),
           FromName = MIN(COALESCE(r.MovementFromName, r.ProposedFromName)),
           ToPlaceId = MIN(COALESCE(r.MovementToPlaceId, r.ProposedToPlaceId)),
           ToName = MIN(COALESCE(r.MovementToName, r.ProposedToName)),
           IsNewLeg = CAST(MAX(CASE WHEN r.Kind IN (N'Ship', N'NextLeg') THEN 1 ELSE 0 END) AS BIT),
           IsStay = CAST(MAX(CASE WHEN COALESCE(r.MovementStage, r.ProposedStage) IN (N'Port', N'Customs', N'Border') THEN 1 ELSE 0 END) AS BIT),
           MovementStartDate = MIN(r.MovementStartDate), MovementPlannedDate = MIN(r.MovementPlannedDate), MovementEta = MIN(r.MovementEta),
           Containers = COUNT(*), MovementContainerCount = MAX(r.MovementContainerCount),
           -- the earliest date of the step for every container of the group: a new leg leaves once the last one arrived
           NotBefore = MAX(CASE WHEN r.Kind IN (N'Ship', N'NextLeg') THEN r.PlaceSince ELSE r.MovementNotBefore END),
           PlaceName = MIN(r.PlaceName),
           ProposalSource = MIN(r.ProposalSource), ProposalLegs = MAX(r.ProposalLegs),
           OnePerContainer = CAST(MAX(CAST(ISNULL(r.ProposedOnePerContainer, 0) AS INT)) AS BIT),
           Drafts = SUM(CAST(r.IsDraft AS INT)), WithoutContainerNo = SUM(1 - CAST(r.HasContainerNo AS INT)),
           WithTypedDates = SUM(CAST(r.HasTypedDates AS INT)),
           OrderCount = MAX(o.OrderCount), SupplierCount = MAX(o.SupplierCount),
           OrderNumbers = MAX(CASE WHEN o.OrderCount = 1 THEN o.FirstOrder
                                   WHEN o.OrderCount > 1 THEN o.FirstOrder + N' +' + CAST(o.OrderCount - 1 AS NVARCHAR(10)) END),
           SupplierNames = MAX(CASE WHEN o.SupplierCount = 1 THEN o.FirstSupplier
                                    WHEN o.SupplierCount > 1 THEN o.FirstSupplier + N' +' + CAST(o.SupplierCount - 1 AS NVARCHAR(10)) END),
           -- "Then": offered when the containers of the group get a next leg after it; its fields when they all get the same
           ThenContainers = SUM(CASE WHEN r.ThenTypeId IS NOT NULL THEN 1 ELSE 0 END),
           ThenSame = CAST(CASE WHEN COUNT(DISTINCT CONCAT(r.ThenTypeId, N'|', r.ThenToPlaceId)) = 1
                                 AND COUNT(r.ThenTypeId) = COUNT(*) THEN 1 ELSE 0 END AS BIT),
           ThenTypeId = MIN(r.ThenTypeId), ThenTypeName = MIN(r.ThenTypeName), ThenStage = MIN(r.ThenStage),
           ThenFromPlaceId = MIN(r.ThenFromPlaceId), ThenFromName = MIN(r.ThenFromName),
           ThenToPlaceId = MIN(r.ThenToPlaceId), ThenToName = MIN(r.ThenToName), ThenIsStay = CAST(MIN(CAST(r.ThenIsStay AS INT)) AS BIT),
           ThenSource = MIN(r.ThenSource), ThenLegs = MAX(r.ThenLegs),
           ThenDefault = CAST(MIN(CAST(r.ThenDefault AS INT)) AS BIT)
    FROM #Row r
    LEFT JOIN #GroupOrders o ON o.GroupKey = r.GroupKey
    WHERE r.CanMove = 1
    GROUP BY r.GroupKey
    ORDER BY CASE MIN(r.Kind) WHEN N'Complete' THEN 1 WHEN N'StartPlanned' THEN 2 ELSE 3 END,
             MIN(COALESCE(r.MovementFromName, r.ProposedFromName)), r.GroupKey;

    -- 5. the containers that cannot move on, by reason (set 3)
    SELECT BlockGroup, Containers = COUNT(*),
           ContainerRefs = STRING_AGG(CAST(CASE WHEN rn <= 5 THEN ISNULL(ContainerRef, CAST(ContainerId AS NVARCHAR(12))) END AS NVARCHAR(MAX)), N', ')
                           WITHIN GROUP (ORDER BY rn)
    FROM (SELECT BlockGroup, ContainerRef, ContainerId,
                 rn = ROW_NUMBER() OVER (PARTITION BY BlockGroup ORDER BY LEN(ContainerRef), ContainerRef, ContainerId)
          FROM #Row WHERE CanMove = 0) z
    GROUP BY BlockGroup
    ORDER BY COUNT(*) DESC, BlockGroup;
END
GO

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
CREATE OR ALTER PROCEDURE logistics.usp_Movement_AddLeg
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

/* ================================================================== 8. The container list: the to-do list */

-- Re-created (81) from the body of script 80: + the next step of each row (NextStepKind, NextStepBlockedReason) and the
-- @NextStep filter, which works with paging and any number of containers ("Start shipment" Ship, "Start planned leg"
-- StartPlanned, "Arrival due" Complete, "Next leg to plan" NextLeg, "Receive goods" Receive and OpenReceipt), and the
-- proposed next leg (Proposed*). The page is found first (step 1: the same filters and order), then the figures of
-- before are worked out for its rows only (step 2, the same columns), then the proposed leg (step 3).
CREATE OR ALTER PROCEDURE logistics.usp_Container_Search
    @Search              NVARCHAR(100) = NULL,   -- ref, container no., B/L, vessel, PO / PI no., commercial invoice, supplier
    @ContainerRef        NVARCHAR(30)  = NULL,
    @ContainerNo         NVARCHAR(20)  = NULL,
    @SupplierId          INT           = NULL,
    @PurchaseDocumentId  INT           = NULL,   -- a purchase ORDER or a purchase INVOICE linked to the container
    @PurchaseOrderId     INT           = NULL,   -- containers carrying lines of this order
    @CommercialInvoiceNo NVARCHAR(50)  = NULL,
    @ItemId              INT           = NULL,
    @BlNo                NVARCHAR(30)  = NULL,
    @Status              TINYINT       = NULL,
    @PortId              INT           = NULL,
    @WarehouseId         INT           = NULL,
    @BranchId            INT           = NULL,
    @MovementId          INT           = NULL,   -- containers of this movement
    @OrderMonthKey       INT           = NULL,   -- e.g. 202601
    @DateFrom            DATE          = NULL,   -- order date
    @DateTo              DATE          = NULL,
    @SortColumn          NVARCHAR(30)  = N'OrderDate',  -- ContainerRef | ContainerNo | OrderDate | DispatchDate | Eta | Status | CreatedAtUtc
    @SortDirection       NVARCHAR(4)   = N'DESC',
    @PageNumber          INT           = 1,
    @PageSize            INT           = 10,
    @DeliveredNotReceived BIT          = 0,      -- (65) 1 = delivered (or with a draft receipt) and not received yet
    @NextStep            NVARCHAR(20)  = NULL    -- (81) Ship | StartPlanned | Complete | NextLeg | Receive (the to-do list)
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 10;
    -- (78) PAGES OF UP TO 5,000 (200 before): every container's figures are worked out before the OFFSET, so each page
    -- costs about the whole search - the 2,000 containers of one order took ten calls of 2 s each. The order's Containers
    -- card and a movement's list now ask for them in one page; the grids keep asking for pages of 200 or less.
    -- (81) Since the page is found first (step 1), only the page's rows are worked out; the cap stays.
    IF @PageSize > 5000 SET @PageSize = 5000;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @ContainerRef = NULLIF(LTRIM(RTRIM(@ContainerRef)), N'');
    SET @ContainerNo = NULLIF(LTRIM(RTRIM(@ContainerNo)), N'');
    SET @CommercialInvoiceNo = NULLIF(LTRIM(RTRIM(@CommercialInvoiceNo)), N'');
    SET @BlNo = NULLIF(LTRIM(RTRIM(@BlNo)), N'');
    SET @NextStep = NULLIF(LTRIM(RTRIM(@NextStep)), N'');
    IF @SortColumn IS NULL OR @SortColumn NOT IN (N'ContainerRef', N'ContainerNo', N'OrderDate', N'DispatchDate', N'Eta', N'Status', N'CreatedAtUtc')
        SET @SortColumn = N'OrderDate';
    IF @SortDirection IS NULL OR UPPER(@SortDirection) NOT IN (N'ASC', N'DESC') SET @SortDirection = N'DESC';
    SET @SortDirection = UPPER(@SortDirection);

    -- (81) 1. THE PAGE FIRST: the filters and the order of before, on what they read only (the container, who received
    -- it, its latest Delivery, its next step for @NextStep), then every figure of the list for the page's rows only.
    -- They were worked out for every container before the OFFSET: 9.5 s a page on 50,000 containers. RECOMPILE: an
    -- empty filter costs nothing (the next step of every container is read only for @NextStep, the latest Delivery
    -- only for @DeliveredNotReceived).
    CREATE TABLE #Pg (Ord INT NOT NULL PRIMARY KEY, Id INT NOT NULL, TotalCount INT NOT NULL);
    INSERT INTO #Pg (Ord, Id, TotalCount)
    SELECT Ord = ROW_NUMBER() OVER (ORDER BY
        -- (78) a ref sorts by its length first: KTG-2026-9999 before KTG-2026-10000 (numbers past NumberLength)
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'ContainerRef' THEN LEN(c.ContainerRef) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'ContainerRef' THEN LEN(c.ContainerRef) END DESC,
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ContainerNo' THEN c.ContainerNo END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'ContainerRef' THEN c.ContainerRef WHEN N'ContainerNo' THEN c.ContainerNo END END DESC,
        CASE WHEN @SortDirection = N'ASC'  THEN CASE @SortColumn WHEN N'OrderDate' THEN c.OrderDate WHEN N'DispatchDate' THEN c.DispatchDate WHEN N'Eta' THEN c.Eta END END ASC,
        CASE WHEN @SortDirection = N'DESC' THEN CASE @SortColumn WHEN N'OrderDate' THEN c.OrderDate WHEN N'DispatchDate' THEN c.DispatchDate WHEN N'Eta' THEN c.Eta END END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'Status' THEN CAST(c.Status AS INT) END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'Status' THEN CAST(c.Status AS INT) END DESC,
        CASE WHEN @SortDirection = N'ASC'  AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END ASC,
        CASE WHEN @SortDirection = N'DESC' AND @SortColumn = N'CreatedAtUtc' THEN c.CreatedAtUtc END DESC,
        c.OrderDate DESC, c.Id DESC), c.Id, COUNT(*) OVER ()
    FROM logistics.Containers c
    -- one row each for a container: OUTER, so that the ones a filter does not read are not read at all
    OUTER APPLY logistics.fn_Container_ReceivedBy(c.Id) rb
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl
    OUTER APPLY logistics.fn_Container_ShipState(c.Id) ss
    OUTER APPLY logistics.fn_Container_NextStepKind(c.Id, c.Status, ss.MovementCount, ss.ActiveMovementId, ss.PlannedMovementId,
                                                    NULL, ss.LastMovementId, dl.MovementId, rb.GoodsReceiptStatus) nk
    WHERE (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
           OR c.BlNo LIKE N'%' + @Search + N'%' OR c.VesselName LIKE N'%' + @Search + N'%'
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                      INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
                      WHERE cl.ContainerId = c.Id AND (d.DocumentNumber LIKE N'%' + @Search + N'%' OR sp.PartyName LIKE N'%' + @Search + N'%'))
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                      INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                      WHERE cl.ContainerId = c.Id AND d.Status <> 3
                        AND (d.DocumentNumber LIKE N'%' + @Search + N'%' OR d.CommercialInvoiceNo LIKE N'%' + @Search + N'%'
                             OR d.ExporterReference LIKE N'%' + @Search + N'%')))
      AND (@ContainerRef IS NULL OR c.ContainerRef LIKE N'%' + @ContainerRef + N'%')
      AND (@ContainerNo IS NULL OR c.ContainerNo LIKE N'%' + @ContainerNo + N'%')
      AND (@BlNo IS NULL OR c.BlNo LIKE N'%' + @BlNo + N'%')
      AND (@Status IS NULL OR c.Status = @Status)
      AND (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND (@WarehouseId IS NULL OR c.WarehouseId = @WarehouseId)
      AND (@PortId IS NULL OR c.PortOfLoadingId = @PortId OR c.PortOfDestinationId = @PortId OR c.FinalDestinationId = @PortId)
      AND (@OrderMonthKey IS NULL OR c.OrderMonthKey = @OrderMonthKey)
      AND (@DateFrom IS NULL OR c.OrderDate >= @DateFrom)
      AND (@DateTo IS NULL OR c.OrderDate <= @DateTo)
      AND (@SupplierId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                          INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                                          WHERE cl.ContainerId = c.Id AND d.SupplierId = @SupplierId))
      AND (@PurchaseOrderId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.PurchaseOrderId = @PurchaseOrderId))
      AND (@PurchaseDocumentId IS NULL
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.PurchaseOrderId = @PurchaseDocumentId)
           OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                      INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                      WHERE cl.ContainerId = c.Id AND pil.DocumentId = @PurchaseDocumentId))
      AND (@CommercialInvoiceNo IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl
                                                   INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                                                   INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                                                   WHERE cl.ContainerId = c.Id AND d.Status <> 3
                                                     AND d.CommercialInvoiceNo LIKE N'%' + @CommercialInvoiceNo + N'%'))
      AND (@ItemId IS NULL OR EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = c.Id AND cl.ItemId = @ItemId))
      AND (@MovementId IS NULL OR EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.ContainerId = c.Id AND mc.MovementId = @MovementId))
      AND (ISNULL(@DeliveredNotReceived, 0) = 0
           OR (c.Status BETWEEN 2 AND 5 AND ISNULL(rb.ReceivedBy, N'') <> N'GRN'
               AND (dl.MovementId IS NOT NULL OR rb.GoodsReceiptStatus = 1)))
      AND (@NextStep IS NULL OR nk.Kind = @NextStep                                     -- (81) the to-do list
           OR (@NextStep = N'Receive' AND nk.Kind = N'OpenReceipt'))
    ORDER BY Ord
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);

    -- 2. the list's figures, for the page's rows. Why a planned movement cannot start yet (fn_Movement_StartBlock) is
    -- read once per planned movement of the page, apart: read through each row's ship state it cost seconds a page.
    SELECT p.MovementId, b.Reason, b.StartNotBefore
    INTO #Sb
    FROM (SELECT DISTINCT MovementId = ss.PlannedMovementId
          FROM #Pg pg CROSS APPLY logistics.fn_Container_ShipState(pg.Id) ss
          WHERE ss.PlannedMovementId IS NOT NULL) p
    CROSS APPLY logistics.fn_Movement_StartBlock(p.MovementId) b;

    SELECT c.Id, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, ct.TypeName AS ContainerTypeName,
           c.OrderDate, c.OrderMonthKey, OrderMonth = FORMAT(c.OrderDate, N'MMM-yyyy', N'en-US'),
           c.BranchId, b.BranchCode, b.BranchName, c.WarehouseId, w.WarehouseCode, w.WarehouseName,
           c.PurchaseOrderId, mpo.DocumentNumber AS PurchaseOrderNumber,
           OrderCount = ISNULL(po.OrderCount, 0),
           OrderNumbers = CASE WHEN ISNULL(po.OrderCount, 0) = 0 THEN NULL
                               WHEN po.OrderCount = 1 THEN po.FirstOrder
                               ELSE po.FirstOrder + N' +' + CAST(po.OrderCount - 1 AS NVARCHAR(10)) END,
           SupplierCount = ISNULL(po.SupplierCount, 0),
           SupplierNames = CASE WHEN ISNULL(po.SupplierCount, 0) = 0 THEN NULL
                                WHEN po.SupplierCount = 1 THEN po.FirstSupplier
                                ELSE po.FirstSupplier + N' +' + CAST(po.SupplierCount - 1 AS NVARCHAR(10)) END,
           InvoiceCount = ISNULL(inv.InvoiceCount, 0),
           InvoiceNumbers = CASE WHEN ISNULL(inv.InvoiceCount, 0) = 0 THEN NULL
                                 WHEN inv.InvoiceCount = 1 THEN inv.FirstInvoice
                                 ELSE inv.FirstInvoice + N' +' + CAST(inv.InvoiceCount - 1 AS NVARCHAR(10)) END,
           CommercialInvoiceNos = CASE WHEN inv.CiCount = 1 THEN inv.FirstCi
                                       WHEN inv.CiCount > 1 THEN inv.FirstCi + N' +' + CAST(inv.CiCount - 1 AS NVARCHAR(10)) END,
           ExporterReferences = CASE WHEN inv.ErCount = 1 THEN inv.FirstEr
                                     WHEN inv.ErCount > 1 THEN inv.FirstEr + N' +' + CAST(inv.ErCount - 1 AS NVARCHAR(10)) END,
           ItemCount = ISNULL(ln.ItemCount, 0),
           ItemSummary = CASE WHEN ISNULL(ln.ItemCount, 0) = 0 THEN NULL
                              WHEN ln.ItemCount = 1 THEN ln.FirstItem
                              ELSE N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           TotalQtyBase = ISNULL(ln.Qty, 0),
           InvoicedQtyBase = ISNULL(inv.PostedQty, 0),
           InvoicingStatus = CASE WHEN ISNULL(inv.PostedQty, 0) = 0 THEN 0
                                  WHEN inv.PostedQty >= ISNULL(ln.Qty, 0) THEN 2 ELSE 1 END,     -- 0 none, 1 partly, 2 fully (posted)
           TotalReceivedBase = c.TotalReceivedBase, c.TotalOilQty,
           fl.FillPct, fl.CapacityKnown, fl.MissingContainerUnitItems, fl.RemainingPcs, fl.IsOverCapacity,
           c.BlNo, c.BlDate, c.DispatchDate, c.Eta, c.ActualPortArrival, c.CustomsReleaseDate, c.OffloadedDate,
           c.FreeDays, c.LastFreeDay,
           DaysAtPort = CASE WHEN c.ActualPortArrival IS NOT NULL      -- (65) up to the receipt, else the Delivery, else today
                             THEN DATEDIFF(DAY, c.ActualPortArrival, COALESCE(c.OffloadedDate, dl.EndDate, CAST(SYSUTCDATETIME() AS DATE))) END,
           c.CurrentLocation, c.Status, c.StatusNote,
           CurrentMovementId = mv.Id, CurrentMovementNo = mv.MovementNo, CurrentMovementStatus = mv.Status,
           ChargesPostedBase = ISNULL(chg.Posted, 0), ChargesDraftBase = ISNULL(chg.Draft, 0),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ContainerId = c.Id),
           pl.PortName AS PortOfLoadingName, pd.PortName AS PortOfDestinationName,
           c.CreatedAtUtc, c.CreatedBy, cu.FullName AS CreatedByName, c.UpdatedAtUtc, c.RowVersion,
           pg.TotalCount,                                              -- (81) of the search (step 1)
           -- (65) goods receipts
           rb.ReceivedBy, rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus,
           DeliveredDate = dl.EndDate,
           CanReceive = CAST(CASE WHEN c.Status BETWEEN 2 AND 5 AND rb.GoodsReceiptId IS NULL THEN 1 ELSE 0 END AS BIT),
           CloseBlockedReason = cb.Reason,
           -- (80) the shipment (fn_Container_ShipState): where it is, the movement in progress carrying it, its next
           -- planned movement (why it cannot start yet, its earliest start) and its last completed one
           ss.MovementCount, ss.PlaceId, ss.PlaceName, ss.PlaceSince,
           ss.ActiveMovementId, ss.ActiveMovementNo, ss.ActiveMovementTypeName, ss.ActiveMovementStage,
           ss.ActiveMovementFromName, ss.ActiveMovementToName, ss.ActiveMovementStartDate, ss.ActiveMovementEta,
           ss.ActiveMovementContainerCount,
           ss.PlannedMovementId, ss.PlannedMovementNo, ss.PlannedMovementTypeName, ss.PlannedMovementStage,
           ss.PlannedMovementFromName, ss.PlannedMovementToName, ss.PlannedMovementDate, ss.PlannedMovementContainerCount,
           PlannedMovementBlockedReason = sb.Reason, PlannedMovementNotBefore = sb.StartNotBefore,   -- (81) once per movement
           ss.LastMovementId, ss.LastMovementNo, ss.LastMovementEndDate,
           -- (81) its next step (fn_Container_NextStepKind), and the planned movement's refusal for this page's rows
           NextStepKind = nk.Kind, NextStepBlockedReason = nk.BlockedReason,
           SortOrd = pg.Ord
    INTO #Page
    FROM #Pg pg
    INNER JOIN logistics.Containers c       ON c.Id = pg.Id      -- (81) the page's rows only
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN purchase.PurchaseDocuments mpo ON mpo.Id = c.PurchaseOrderId
    LEFT  JOIN security.Users cu            ON cu.Id = c.CreatedBy
    CROSS APPLY logistics.fn_ContainerFill(c.Id) fl
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb      -- (65) who received it; its open goods receipt
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl    -- (65) its latest completed Delivery
    OUTER APPLY (SELECT b.Reason FROM logistics.fn_Container_CloseBlock(c.Id) b WHERE c.Status = 6) cb  -- (65) why not Close
    CROSS APPLY logistics.fn_Container_ShipState(c.Id) ss       -- (80) the shipment
    LEFT  JOIN #Sb sb                       ON sb.MovementId = ss.PlannedMovementId          -- (81)
    CROSS APPLY logistics.fn_Container_NextStepKind(c.Id, c.Status, ss.MovementCount, ss.ActiveMovementId, ss.PlannedMovementId,
                                                    sb.Reason, ss.LastMovementId, dl.MovementId,
                                                    rb.GoodsReceiptStatus) nk   -- (81) its next step
    OUTER APPLY (SELECT OrderCount = COUNT(DISTINCT cl.PurchaseOrderId), SupplierCount = COUNT(DISTINCT d.SupplierId),
                        FirstOrder = MIN(d.DocumentNumber), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = c.Id) po
    OUTER APPLY (SELECT InvoiceCount = COUNT(DISTINCT d.Id),
                        CiCount = COUNT(DISTINCT d.CommercialInvoiceNo), ErCount = COUNT(DISTINCT d.ExporterReference),
                        FirstInvoice = MIN(d.DocumentNumber), FirstCi = MIN(d.CommercialInvoiceNo), FirstEr = MIN(d.ExporterReference),
                        PostedQty = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase ELSE 0 END)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                 INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                 WHERE cl.ContainerId = c.Id AND d.Status <> 3) inv
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), Qty = SUM(cl.QuantityBase), FirstItem = MIN(i.ItemName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 WHERE cl.ContainerId = c.Id) ln
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN ch.Status = 2 THEN ch.AmountBase END),
                        Draft  = SUM(CASE WHEN ch.Status = 1 THEN ch.AmountBase END)
                 FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id) chg
    OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, m.Status
                 FROM logistics.MovementContainers mc
                 INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                 WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)
                 ORDER BY CASE WHEN m.Status = 2 THEN 0 ELSE 1 END, COALESCE(m.EndDate, m.StartDate) DESC, m.Id DESC) mv;

    -- 3. THE PROPOSED NEXT LEG (Ship, NextLeg: "Inland transport to Kasumbalesa..."), the usual leg from a place worked
    -- out once per (place, last stage) of the page, not once per row.
    SELECT p.Id AS ContainerId, p.PlaceId, LastStage = CASE WHEN p.MovementCount = 0 THEN NULL ELSE lt.Stage END,
           IsCleared = CAST(CASE WHEN p.Status = 5 THEN 1 ELSE 0 END AS BIT)
    INTO #Leg
    FROM #Page p
    LEFT JOIN logistics.Movements lm      ON lm.Id = p.LastMovementId
    LEFT JOIN masterdata.MovementTypes lt ON lt.Id = lm.MovementTypeId
    WHERE p.NextStepKind IN (N'Ship', N'NextLeg');

    SELECT g.PlaceId, g.LastStage, h.MovementTypeId, h.ToPlaceId, h.Legs
    INTO #Hist
    FROM (SELECT DISTINCT PlaceId, LastStage FROM #Leg WHERE PlaceId IS NOT NULL) g
    CROSS APPLY logistics.fn_Movement_NextLegHistory(g.PlaceId, g.LastStage) h;

    SELECT p.*,
           ProposedTypeId = pr.TypeId, ProposedTypeCode = pr.TypeCode, ProposedTypeName = pr.TypeName, ProposedStage = pr.Stage,
           ProposedFromPlaceId = pr.FromPlaceId, ProposedFromName = pr.FromName,
           ProposedToPlaceId = pr.ToPlaceId, ProposedToName = pr.ToName,
           ProposalSource = pr.Source, ProposalLegs = pr.Legs, ProposedIsStay = pr.IsStay
    FROM #Page p
    LEFT JOIN #Leg l  ON l.ContainerId = p.Id
    LEFT JOIN #Hist h ON h.PlaceId = l.PlaceId AND ISNULL(h.LastStage, N'') = ISNULL(l.LastStage, N'')
    OUTER APPLY (SELECT x.*
                 FROM logistics.fn_Container_NextLegProposal(p.Id, l.PlaceId, l.LastStage, l.IsCleared,
                                                             h.MovementTypeId, h.ToPlaceId, h.Legs) x
                 WHERE l.ContainerId IS NOT NULL) pr
    ORDER BY p.SortOrd;
END
GO

/* ================================================================== 9. The container page: its next step */

-- Re-created (81) from the body of script 80: + the next step columns at the end of set 1 (fn_Container_NextStep): the
-- button's label ("Cleared customs at Kasumbalesa...", "Inland transport to Kasumbalesa...") and where the proposal
-- came from. The other sets are unchanged.
CREATE OR ALTER PROCEDURE logistics.usp_Container_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT c.Id, c.DocumentTypeId, c.ContainerRef, c.ContainerNo,
           c.ContainerTypeId, ct.TypeCode AS ContainerTypeCode, ct.TypeName AS ContainerTypeName,
           ct.MaxWeightKg, ct.MaxVolumeCbm,
           c.SealNo, c.CustomsSealNo, c.Description,
           c.OrderDate, c.OrderMonthKey, OrderMonth = FORMAT(c.OrderDate, N'MMM-yyyy', N'en-US'),
           c.ShippingMethod, c.CountryOfOrigin,
           c.PurchaseOrderId, mpo.DocumentNumber AS PurchaseOrderNumber, mpo.SupplierId AS PurchaseOrderSupplierId,
           mps.PartyName AS PurchaseOrderSupplierName,
           c.ForwarderId, fw.PartyName AS ForwarderName, c.TransporterId, tr.PartyName AS TransporterName,
           c.ShippingLine, c.VesselName, c.VoyageNo, c.BookingNo,
           c.PortOfLoadingId, pl.PortName AS PortOfLoadingName, pl.CountryCode AS PortOfLoadingCountry,
           c.PortOfDestinationId, pd.PortName AS PortOfDestinationName, pd.CountryCode AS PortOfDestinationCountry,
           c.FinalDestinationId, fd.PortName AS FinalDestinationName,
           c.DispatchDate, c.Eta, c.FreeDays, c.LastFreeDay, c.GrossWeightKg, c.VolumeCbm, c.Packages,
           c.BlNo, c.BlDate, c.BlNotes,
           c.TotalLines, c.TotalAllocatedBase, c.TotalReceivedBase, c.TotalOilQty,
           fl.FillPct, fl.CapacityKnown, fl.MissingContainerUnitItems, fl.RemainingPcs, fl.IsOverCapacity,
           c.BranchId, b.BranchCode, b.BranchName, c.WarehouseId, w.WarehouseCode, w.WarehouseName,
           c.TruckNo, c.WaybillNo, c.DeclarationNo, c.FeriNo,
           c.ActualPortArrival, c.BorderCrossingDate, c.CustomsReleaseDate,
           DaysAtPort = CASE WHEN c.ActualPortArrival IS NOT NULL      -- (65) up to the receipt, else the Delivery, else today
                             THEN DATEDIFF(DAY, c.ActualPortArrival, COALESCE(c.OffloadedDate, dl.EndDate, CAST(SYSUTCDATETIME() AS DATE))) END,
           c.OffloadedDate, c.OffloadedAtUtc, c.OffloadedBy, ou.FullName AS OffloadedByName,
           c.Status, c.StatusNote, c.CurrentLocation, c.Notes,
           c.DatesFromMovements,
           HasMovements = CAST(CASE WHEN EXISTS (SELECT 1 FROM logistics.MovementContainers mc
                                                 INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                                                 WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)) THEN 1 ELSE 0 END AS BIT),
           InvoicedPostedBase = ISNULL(inv.Posted, 0), InvoicedDraftBase = ISNULL(inv.Draft, 0),
           IsFullyInvoiced = CAST(CASE WHEN c.TotalAllocatedBase > 0 AND NOT EXISTS
                                       (SELECT 1 FROM logistics.ContainerLines cl
                                        OUTER APPLY (SELECT Q = SUM(pil.QuantityBase) FROM purchase.PurchaseDocumentLines pil
                                                     INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                                                     WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (2, 4)) q
                                        WHERE cl.ContainerId = c.Id AND ISNULL(q.Q, 0) < cl.QuantityBase) THEN 1 ELSE 0 END AS BIT),
           ChargesPostedBase = ISNULL(chg.Posted, 0), ChargesDraftBase = ISNULL(chg.Draft, 0),
           ChargesLandedPostedBase = ISNULL(chg.LandedPosted, 0),
           FobTotalBase = cost.Fob, LandedTotalBase = cost.Fob + ISNULL(chg.LandedPosted, 0),
           c.ConfirmedAtUtc, c.ConfirmedBy, fu.FullName AS ConfirmedByName,
           c.ClosedAtUtc, c.ClosedBy, ku.FullName AS ClosedByName,
           c.CancelledAtUtc, c.CancelledBy, xu.FullName AS CancelledByName, c.CancelReason,
           c.CreatedAtUtc, c.CreatedBy, cu.FullName AS CreatedByName,
           c.UpdatedAtUtc, c.UpdatedBy, uu.FullName AS UpdatedByName, c.RowVersion,
           -- (65) goods receipts
           rb.ReceivedBy,
           rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus,
           GoodsReceiptDate = gr.DocumentDate, GoodsReceiptIsAuto = gr.IsAuto,
           GoodsReceiptWarehouseId = gr.WarehouseId, GoodsReceiptWarehouseCode = gw.WarehouseCode,
           GoodsReceiptCreatedAtUtc = gr.CreatedAtUtc,
           DeliveredDate = dl.EndDate, DeliveryMovementId = dl.MovementId, DeliveryMovementNo = dl.MovementNo,
           DeliveryPlaceName = dl.PlaceName,
           CanReceive = CAST(CASE WHEN c.Status BETWEEN 2 AND 5 AND rb.GoodsReceiptId IS NULL THEN 1 ELSE 0 END AS BIT),
           CloseBlockedReason = cb.Reason,
           -- (80) the shipment (fn_Container_ShipState): where it is, the movement in progress carrying it, its next
           -- planned movement (why it cannot start yet, its earliest start) and its last completed one
           ss.MovementCount, ss.PlaceId, ss.PlaceName, ss.PlaceSince,
           ss.ActiveMovementId, ss.ActiveMovementNo, ss.ActiveMovementTypeName, ss.ActiveMovementStage,
           ss.ActiveMovementFromName, ss.ActiveMovementToName, ss.ActiveMovementStartDate, ss.ActiveMovementEta,
           ss.ActiveMovementContainerCount,
           ss.PlannedMovementId, ss.PlannedMovementNo, ss.PlannedMovementTypeName, ss.PlannedMovementStage,
           ss.PlannedMovementFromName, ss.PlannedMovementToName, ss.PlannedMovementDate, ss.PlannedMovementContainerCount,
           ss.PlannedMovementBlockedReason, ss.PlannedMovementNotBefore,
           ss.LastMovementId, ss.LastMovementNo, ss.LastMovementEndDate,
           -- (81) its next step (fn_Container_NextStep): the label of its button, the proposed next leg, and for a movement
           -- to complete the leg proposed after it
           NextStepKind = nx.Kind, NextStepBlockedReason = nx.BlockedReason, nx.HasTypedDates, nx.PlaceKind, nx.LastStage,
           NextStepMovementId = nx.MovementId, NextStepMovementNo = nx.MovementNo, NextStepMovementStage = nx.MovementStage,
           NextStepMovementTypeName = nx.MovementTypeName, NextStepMovementToName = nx.MovementToName,
           NextStepMovementContainerCount = nx.MovementContainerCount, NextStepNotBefore = nx.MovementNotBefore,
           nx.ProposedTypeId, nx.ProposedTypeCode, nx.ProposedTypeName, nx.ProposedStage,
           nx.ProposedFromPlaceId, nx.ProposedFromName, nx.ProposedToPlaceId, nx.ProposedToName,
           nx.ProposalSource, nx.ProposalLegs, nx.ProposedIsStay,
           nx.ThenTypeId, nx.ThenTypeName, nx.ThenStage, nx.ThenToPlaceId, nx.ThenToName, nx.ThenIsStay, nx.ThenDefault
    FROM logistics.Containers c
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    CROSS APPLY logistics.fn_ContainerFill(c.Id) fl
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) rb      -- (65) who received it; its open goods receipt
    OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl    -- (65) its latest completed Delivery
    OUTER APPLY (SELECT b.Reason FROM logistics.fn_Container_CloseBlock(c.Id) b WHERE c.Status = 6) cb  -- (65) why not Close
    CROSS APPLY logistics.fn_Container_ShipState(c.Id) ss       -- (80) the shipment
    OUTER APPLY logistics.fn_Container_NextStep(c.Id) nx        -- (81) its next step
    LEFT  JOIN purchase.GoodsReceipts gr    ON gr.Id = rb.GoodsReceiptId
    LEFT  JOIN masterdata.Warehouses gw     ON gw.Id = gr.WarehouseId
    LEFT  JOIN purchase.PurchaseDocuments mpo ON mpo.Id = c.PurchaseOrderId
    LEFT  JOIN masterdata.Parties mps       ON mps.Id = mpo.SupplierId
    LEFT  JOIN masterdata.Parties fw        ON fw.Id = c.ForwarderId
    LEFT  JOIN masterdata.Parties tr        ON tr.Id = c.TransporterId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN masterdata.Ports fd          ON fd.Id = c.FinalDestinationId
    LEFT  JOIN security.Users ou ON ou.Id = c.OffloadedBy
    LEFT  JOIN security.Users fu ON fu.Id = c.ConfirmedBy
    LEFT  JOIN security.Users ku ON ku.Id = c.ClosedBy
    LEFT  JOIN security.Users xu ON xu.Id = c.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = c.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = c.UpdatedBy
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase END),
                        Draft  = SUM(CASE WHEN d.Status = 1 THEN pil.QuantityBase END)
                 FROM logistics.ContainerLines cl
                 INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
                 INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
                 WHERE cl.ContainerId = c.Id) inv
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN ch.Status = 2 THEN ch.AmountBase END),
                        Draft  = SUM(CASE WHEN ch.Status = 1 THEN ch.AmountBase END),
                        LandedPosted = SUM(CASE WHEN ch.Status = 2 AND ch.IncludeInLandedCost = 1 THEN ch.AmountBase END)
                 FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id) chg
    OUTER APPLY (SELECT Fob = SUM(CAST(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase) AS DECIMAL(18,6)) * ISNULL(u.UnitFob, 0))
                 FROM logistics.ContainerLines cl
                 OUTER APPLY (SELECT UnitFob = COALESCE(cl.FobCostBase,
                                                        (SELECT SUM(pil.LineTotal / pid.ExchangeRate) / NULLIF(SUM(pil.QuantityBase), 0)
                                                         FROM purchase.PurchaseDocumentLines pil
                                                         INNER JOIN purchase.PurchaseDocuments pid ON pid.Id = pil.DocumentId
                                                         WHERE pil.ContainerLineId = cl.Id AND pid.Status IN (1, 2, 4)),
                                                        (SELECT pol.LineTotal / pod.ExchangeRate / NULLIF(pol.QuantityBase, 0)
                                                         FROM purchase.PurchaseDocumentLines pol
                                                         INNER JOIN purchase.PurchaseDocuments pod ON pod.Id = pol.DocumentId
                                                         WHERE pol.Id = cl.PoLineId))) u
                 WHERE cl.ContainerId = c.Id) cost
    WHERE c.Id = @Id;

    -- 2: lines. FOB per unit: once the goods are received the container line's value (frozen by an offload of before; set by
    -- the goods receipt and moved by the invoices since), else the invoices (posted or draft), else the order price.
    SELECT cl.Id, cl.ContainerId, cl.LineNumber,
           cl.PurchaseOrderId, po.DocumentNumber AS PurchaseOrderNumber, po.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           cl.PoLineId, pol.LineNumber AS PoLineNumber,
           cl.ItemId, i.ItemCode, i.ItemName, i.Model, br.BrandName,
           cl.ItemUnitId, ut.UnitTypeName, cl.PackingFormula,
           PoUnitTypeName = pt.UnitTypeName, PoPackingFormula = pol.PackingFormula,
           PcsPerContainer = ipc.PcsPerContainer,
           cl.Quantity, cl.QuantityBase, cl.OilIncluded, cl.OilQtyPerUnit, cl.TotalOilQty,
           OrderedBase = pol.QuantityBase,
           LoadedElsewhereBase = ISNULL(oth.Qty, 0),
           InvoicedPostedBase = ISNULL(inv.Posted, 0), InvoicedDraftBase = ISNULL(inv.Draft, 0),
           AvailableToInvoiceBase = cl.QuantityBase - ISNULL(inv.Posted, 0) - ISNULL(inv.Draft, 0),
           InvoiceNumbers = inv.Numbers,
           cl.ReceivedQuantityBase, cl.VarianceReason, cl.Notes,
           UnitFobBase = COALESCE(cl.FobCostBase, inv.UnitValue, pol.LineTotal / po.ExchangeRate / NULLIF(pol.QuantityBase, 0)),
           FobSource = CASE WHEN cl.FobCostBase IS NOT NULL THEN N'Received' WHEN inv.UnitValue IS NOT NULL THEN N'Invoice' ELSE N'Order' END,
           cl.FobCostBase, cl.ChargesBase,
           DraftChargesBase = ISNULL(dch.Draft, 0),
           ChargesPerUnitBase = cl.ChargesBase / NULLIF(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase), 0),
           LandedCostBase = COALESCE(cl.LandedCostBase,
                                     COALESCE(inv.UnitValue, pol.LineTotal / po.ExchangeRate / NULLIF(pol.QuantityBase, 0))
                                     + cl.ChargesBase / NULLIF(cl.QuantityBase, 0)),
           IsLandedFinal = CAST(CASE WHEN cl.LandedCostBase IS NOT NULL THEN 1 ELSE 0 END AS BIT),
           i.WeightKg, i.VolumeCbm
    FROM logistics.ContainerLines cl
    INNER JOIN purchase.PurchaseDocuments po     ON po.Id = cl.PurchaseOrderId
    INNER JOIN masterdata.Parties sp             ON sp.Id = po.SupplierId
    INNER JOIN purchase.PurchaseDocumentLines pol ON pol.Id = cl.PoLineId
    INNER JOIN inventory.ItemUnits piu           ON piu.Id = pol.ItemUnitId
    INNER JOIN masterdata.UnitTypes pt           ON pt.Id = piu.UnitTypeId
    INNER JOIN inventory.Items i                 ON i.Id = cl.ItemId
    INNER JOIN masterdata.Brands br              ON br.Id = i.BrandId
    INNER JOIN inventory.ItemUnits iu            ON iu.Id = cl.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut           ON ut.Id = iu.UnitTypeId
    CROSS APPLY logistics.fn_ItemPcsPerContainer(cl.ItemId) ipc
    OUTER APPLY (SELECT Qty = SUM(o.QuantityBase) FROM logistics.ContainerLines o
                 INNER JOIN logistics.Containers oc ON oc.Id = o.ContainerId
                 WHERE o.PoLineId = cl.PoLineId AND o.ContainerId <> cl.ContainerId AND oc.Status <> 8) oth
    OUTER APPLY (SELECT Posted = SUM(CASE WHEN d.Status IN (2, 4) THEN pil.QuantityBase END),
                        Draft  = SUM(CASE WHEN d.Status = 1 THEN pil.QuantityBase END),
                        UnitValue = SUM(pil.LineTotal / d.ExchangeRate) / NULLIF(SUM(pil.QuantityBase), 0),
                        Numbers = STRING_AGG(d.DocumentNumber, N', ')
                 FROM purchase.PurchaseDocumentLines pil
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = pil.DocumentId
                 WHERE pil.ContainerLineId = cl.Id AND d.Status <> 3) inv
    OUTER APPLY (SELECT Draft = SUM(a.AmountBase) FROM logistics.ContainerChargeAllocations a
                 INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId
                 WHERE a.ContainerLineId = cl.Id AND ch.Status = 1) dch
    WHERE cl.ContainerId = @Id
    ORDER BY cl.LineNumber;

    -- 3: invoices of the container (derived from the invoice lines)
    SELECT d.Id AS PurchaseDocumentId, d.DocumentNumber, d.DocumentDate, d.Status AS InvoiceStatus, d.ReceiptMode,
           d.SourceDocumentId AS PurchaseOrderId, po.DocumentNumber AS PurchaseOrderNumber,
           d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, cur.CurrencyCode, cur.Symbol AS CurrencySymbol, d.ExchangeRate,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo,
           QtyInContainerBase = SUM(pil.QuantityBase),
           AmountInContainer = SUM(pil.LineTotal),
           AmountInContainerBase = SUM(pil.LineTotal / d.ExchangeRate),
           d.TotalAmount, d.TotalAmountBase
    FROM logistics.ContainerLines cl
    INNER JOIN purchase.PurchaseDocumentLines pil ON pil.ContainerLineId = cl.Id
    INNER JOIN purchase.PurchaseDocuments d        ON d.Id = pil.DocumentId
    INNER JOIN masterdata.Parties sp               ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies cur           ON cur.Id = d.CurrencyId
    LEFT  JOIN purchase.PurchaseDocuments po       ON po.Id = d.SourceDocumentId
    WHERE cl.ContainerId = @Id AND d.Status <> 3
    GROUP BY d.Id, d.DocumentNumber, d.DocumentDate, d.Status, d.ReceiptMode, d.SourceDocumentId, po.DocumentNumber,
             d.SupplierId, sp.PartyCode, sp.PartyName, d.CurrencyId, cur.CurrencyCode, cur.Symbol, d.ExchangeRate,
             d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo, d.TotalAmount, d.TotalAmountBase
    ORDER BY d.DocumentDate, d.Id;

    -- 4: movements of the container (the route), oldest first
    SELECT m.Id AS MovementId, m.MovementNo, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.CountryCode AS FromCountry, fp.Kind AS FromKind,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.CountryCode AS ToCountry, tp.Kind AS ToKind,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status,
           m.CarrierPartyId, cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo, m.Reference, m.Notes,
           ContainerCount = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = m.Id),
           ChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch
                          WHERE ch.ContainerId = @Id AND ch.MovementId = m.Id AND ch.Status = 2),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ContainerId = @Id AND a.MovementId = m.Id)
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Movements m       ON m.Id = mc.MovementId
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId
    WHERE mc.ContainerId = @Id
    ORDER BY CASE m.Status WHEN 4 THEN 1 ELSE 0 END, COALESCE(m.StartDate, m.PlannedDate, CAST(m.CreatedAtUtc AS DATE)), m.Id;

    -- 5: charges of the container
    SELECT ch.Id, ch.ContainerId, ch.MovementId, m.MovementNo, ch.GroupId,
           GroupSize = CASE WHEN ch.GroupId IS NULL THEN 1 ELSE (SELECT COUNT(*) FROM logistics.ContainerCharges g WHERE g.GroupId = ch.GroupId) END,
           ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description, ch.ProviderPartyId, pp.PartyName AS ProviderName, ch.Reference,
           ch.ChargeDate, ch.CurrencyId, cur.CurrencyCode, ch.RateType, ch.ExchangeRate, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.AppliedAtOffload, ch.AdjustedAfterOffload,
           AllocatedBase = (SELECT SUM(a.AmountBase) FROM logistics.ContainerChargeAllocations a WHERE a.ChargeId = ch.Id),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ChargeId = ch.Id),
           ch.Notes, ch.PostedAtUtc, pu.FullName AS PostedByName, ch.CancelledAtUtc, ch.CancelReason,
           ch.CreatedAtUtc, cu.FullName AS CreatedByName, ch.RowVersion
    FROM logistics.ContainerCharges ch
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    LEFT  JOIN logistics.Movements m     ON m.Id = ch.MovementId
    LEFT  JOIN security.Users pu         ON pu.Id = ch.PostedBy
    LEFT  JOIN security.Users cu         ON cu.Id = ch.CreatedBy
    WHERE ch.ContainerId = @Id
    ORDER BY ch.ChargeDate, ch.Id;

    -- 6: how every charge is divided over the lines (the real cost of each item)
    SELECT a.ChargeId, a.ContainerLineId, cl.LineNumber, cl.ItemId, i.ItemCode, i.ItemName,
           a.Basis, a.AmountBase, a.IsManual,
           PerUnitBase = a.AmountBase / NULLIF(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase), 0)
    FROM logistics.ContainerChargeAllocations a
    INNER JOIN logistics.ContainerCharges ch ON ch.Id = a.ChargeId
    INNER JOIN logistics.ContainerLines cl   ON cl.Id = a.ContainerLineId
    INNER JOIN inventory.Items i             ON i.Id = cl.ItemId
    WHERE ch.ContainerId = @Id
    ORDER BY a.ChargeId, cl.LineNumber;

    -- 7: attachments (general, per movement, per charge); SharedWith = other containers holding the same file
    SELECT a.Id, a.ContainerId, a.MovementId, m.MovementNo, a.ChargeId, a.AttachmentTypeId, at.Category, at.SubType,
           a.FileId, f.FileName, f.ContentType, f.SizeBytes, a.Note, a.DocumentDate, a.GroupId,
           SharedWith = (SELECT COUNT(*) FROM logistics.ContainerAttachments s WHERE s.FileId = a.FileId AND s.Id <> a.Id),
           a.CreatedAtUtc, a.CreatedBy, u.FullName AS CreatedByName
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Files f ON f.Id = a.FileId
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    LEFT  JOIN logistics.Movements m         ON m.Id = a.MovementId
    LEFT  JOIN security.Users u              ON u.Id = a.CreatedBy
    WHERE a.ContainerId = @Id
    ORDER BY a.CreatedAtUtc DESC, a.Id DESC;

    -- 8: audit
    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM logistics.ContainerAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.ContainerId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END
GO

/* ================================================================== 10. Cancel: only the last leg of a container */

-- Re-created (81) from the body of script 80: + Cancel refuses a movement that is not the last leg (not cancelled) of
-- one of its containers (70010); + Start reads each container's previous movement for itself (70016, 70018: the same
-- rules and messages, seconds less on a large database). Complete is unchanged.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_SetStatus
    @Id         INT,
    @Action     NVARCHAR(10),
    @Date       DATE          = NULL,    -- Start: start date; Complete: end date (default today)
    @Reason     NVARCHAR(300) = NULL,    -- Cancel
    @RowVersion BINARY(8)     = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Action = NULLIF(LTRIM(RTRIM(@Action)), N'');
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Date IS NULL SET @Date = CAST(SYSUTCDATETIME() AS DATE);
    IF @Action IS NULL OR @Action NOT IN (N'Start', N'Complete', N'Cancel') THROW 70000, 'Action must be Start, Complete or Cancel.', 1;

    DECLARE @Status TINYINT, @StartDate DATE, @Label NVARCHAR(300), @FromPlaceId INT, @ToPlaceId INT, @MovementTypeId INT,
            @MovementNo NVARCHAR(30);
    SELECT @Status = m.Status, @StartDate = m.StartDate, @MovementNo = m.MovementNo,
           @FromPlaceId = m.FromPlaceId, @ToPlaceId = m.ToPlaceId, @MovementTypeId = m.MovementTypeId,
           @Label = m.MovementNo + N' ' + mt.TypeName + N': ' + fp.PortName + N' ' + NCHAR(8594) + N' ' + tp.PortName
    FROM logistics.Movements m WITH (UPDLOCK, HOLDLOCK)
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp ON tp.Id = m.ToPlaceId
    WHERE m.Id = @Id;

    IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 70004, 'This movement was modified by another user. Reload the page and try again.', 1;
    IF @Action = N'Start' AND @Status <> 1 THROW 70010, 'Only a planned movement can be started.', 1;
    IF @Action = N'Complete' AND @Status <> 2 THROW 70010, 'Only a movement in progress can be completed.', 1;
    IF @Action = N'Complete' AND @Date < @StartDate THROW 70000, 'The end date cannot be earlier than the start date.', 1;
    IF @Action = N'Cancel' AND @Status = 4 THROW 70010, 'The movement is already cancelled.', 1;
    IF @Action = N'Cancel' AND @Reason IS NULL THROW 70000, 'A cancellation reason is required.', 1;
    -- (80) THE OWNER'S DECISION: A START AND AN ARRIVAL RECORD FACTS, never a plan (a plan is the planned date). One day of
    -- tolerance, as for the document dates: the date is the reader's, SYSUTCDATETIME() the server's in UTC.
    IF @Action = N'Start' AND @Date > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 70000, 'The start date cannot be in the future: start the movement on the day it really leaves.', 1;
    IF @Action = N'Complete' AND @Date > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 70000, 'The end date cannot be in the future: complete the movement on the day it really arrives.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.MovementContainers WHERE MovementId = @Id) AND @Action = N'Start'
        THROW 70000, 'Tick at least one container before starting.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.MovementContainers WHERE MovementId = @Id) AND @Action = N'Complete'
        THROW 70000, 'The movement has no containers.', 1;

    DECLARE @Msg NVARCHAR(400);
    IF @Action = N'Start'
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + CASE WHEN c.Status = 1 THEN N' is not confirmed yet.'
                                                                    ELSE N' is already offloaded, closed or cancelled.' END
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        WHERE mc.MovementId = @Id AND (c.Status = 1 OR c.Status >= 6)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is already travelling with movement ' + m.MovementNo + N'. Complete it first.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c         ON c.Id = mc.ContainerId
        INNER JOIN logistics.MovementContainers o ON o.ContainerId = mc.ContainerId AND o.MovementId <> @Id
        INNER JOIN logistics.Movements m          ON m.Id = o.MovementId AND m.Status = 2
        WHERE mc.MovementId = @Id
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70012, @Msg, 1;

        -- the place rules (script 53): the previous movement of every container is completed (70016), then every
        -- container fits the movement's From, To and stage (70015) - the rules of Save, fn_ContainerFitForMovement
        -- (81) each container's previous movement read for itself (fn_Container_PreviousMovement, the "previous" of
        -- fn_ContainerPlaceForMovement): through the function over every container, the search for the first refusal
        -- in ref order walked all the containers of the database - 18 s a Start on 50,000 containers.
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N': the previous movement ' + pm.MovementNo + N' (' + pf.PortName
                              + N' ' + NCHAR(8594) + N' ' + pt.PortName + N') is not completed yet.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        CROSS APPLY logistics.fn_Container_PreviousMovement(mc.ContainerId, @Id) pm
        INNER JOIN masterdata.Ports pf    ON pf.Id = pm.FromPlaceId
        INNER JOIN masterdata.Ports pt    ON pt.Id = pm.ToPlaceId
        WHERE mc.MovementId = @Id AND pm.Status <> 3
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70016, @Msg, 1;

        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' cannot leave from ' + f.PortName + N'. ' + p.Reason
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        INNER JOIN logistics.fn_ContainerFitForMovement(@Id, @FromPlaceId, @ToPlaceId, @MovementTypeId) p ON p.ContainerId = mc.ContainerId
        INNER JOIN masterdata.Ports f     ON f.Id = @FromPlaceId
        WHERE mc.MovementId = @Id AND p.Fits = 0
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70015, @Msg, 1;

        -- (80) NOT BEFORE THE PREVIOUS LEG ENDED (70018): a container cannot set off from a place before it got there.
        -- The previous movement is completed here (70016 above); its end date is the earliest start.
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' cannot start ' + @MovementNo + N' before ' + pm.MovementNo
                              + N' reached ' + tp.PortName + N' on ' + CONVERT(NVARCHAR(10), pm.EndDate, 103) + N'.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        CROSS APPLY logistics.fn_Container_PreviousMovement(mc.ContainerId, @Id) pm                      -- (81)
        INNER JOIN masterdata.Ports tp    ON tp.Id = pm.ToPlaceId
        WHERE mc.MovementId = @Id AND pm.EndDate > @Date
        ORDER BY pm.EndDate DESC, c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70018, @Msg, 1;
    END
    IF @Action = N'Cancel'
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is already offloaded: its route can no longer change.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        WHERE mc.MovementId = @Id AND c.Status IN (6, 7) AND @Status IN (2, 3)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

        -- (81) ONLY THE LAST LEG OF A CONTAINER CAN BE CANCELLED (70010): a later leg (planned, in progress or completed)
        -- left from this one's To, so cancelling this one would leave the container at a place it never reached and
        -- break its chain of places. The latest one is named: it is the one to cancel first.
        -- A PLANNED leg that a later leg already passed (started or completed after it: data of before script 80) never
        -- happened and is no part of the chain: it may be cancelled - Delete refuses it once a charge or a file names it.
        SELECT TOP (1) @Msg = @MovementNo + N' is not the last leg of ' + c.ContainerRef + N': cancel ' + l.MovementNo + N' first.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        CROSS APPLY (SELECT TOP (1) m.MovementNo
                     FROM logistics.MovementContainers lc
                     INNER JOIN logistics.Movements m ON m.Id = lc.MovementId
                     WHERE lc.ContainerId = mc.ContainerId AND m.Id > @Id AND m.Status <> 4
                     ORDER BY m.Id DESC) l
        WHERE mc.MovementId = @Id
          AND NOT (@Status = 1 AND EXISTS (SELECT 1
                                           FROM logistics.MovementContainers pc
                                           INNER JOIN logistics.Movements pm ON pm.Id = pc.MovementId
                                           WHERE pc.ContainerId = mc.ContainerId AND pm.Id > @Id AND pm.Status IN (2, 3)))
        ORDER BY LEN(c.ContainerRef), c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70010, @Msg, 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE logistics.Movements
        SET Status = CASE @Action WHEN N'Start' THEN 2 WHEN N'Complete' THEN 3 ELSE 4 END,
            StartDate = CASE WHEN @Action = N'Start' THEN @Date ELSE StartDate END,
            EndDate = CASE WHEN @Action = N'Complete' THEN @Date ELSE EndDate END,
            StartedAtUtc = CASE WHEN @Action = N'Start' THEN SYSUTCDATETIME() ELSE StartedAtUtc END,
            StartedBy = CASE WHEN @Action = N'Start' THEN @UserId ELSE StartedBy END,
            CompletedAtUtc = CASE WHEN @Action = N'Complete' THEN SYSUTCDATETIME() ELSE CompletedAtUtc END,
            CompletedBy = CASE WHEN @Action = N'Complete' THEN @UserId ELSE CompletedBy END,
            CancelledAtUtc = CASE WHEN @Action = N'Cancel' THEN SYSUTCDATETIME() ELSE CancelledAtUtc END,
            CancelledBy = CASE WHEN @Action = N'Cancel' THEN @UserId ELSE CancelledBy END,
            CancelReason = CASE WHEN @Action = N'Cancel' THEN @Reason ELSE CancelReason END,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT mc.ContainerId, N'Event',
               LEFT(CASE @Action WHEN N'Start' THEN N'Started ' WHEN N'Complete' THEN N'Arrived / completed ' ELSE N'Cancelled ' END
                    + @Label + N' on ' + CONVERT(NVARCHAR(10), @Date, 23) + ISNULL(N' - ' + @Reason, N''), 500),
               @UserId
        FROM logistics.MovementContainers mc WHERE mc.MovementId = @Id;

        -- (65) RULE 22: CANCELLING A COMPLETED DELIVERY TAKES BACK THE DRAFT GOODS RECEIPTS ITS COMPLETION CREATED (IsAuto,
        -- MovementId = this movement), edited or not - the cancel dialog names the edited ones first (usp_Movement_Get).
        -- A draft made by hand is kept. A posted receipt made its container Offloaded, so the check above refused the
        -- cancel. The same plain deletes as usp_GoodsReceipt_Delete: a draft has no stock, number or cost to undo.
        IF @Action = N'Cancel' AND @Status = 3
        BEGIN
            DECLARE @AutoDrafts TABLE (Id INT NOT NULL PRIMARY KEY, ContainerId INT NOT NULL);
            INSERT INTO @AutoDrafts (Id, ContainerId)
            SELECT g.Id, g.ContainerId
            FROM purchase.GoodsReceipts g WITH (UPDLOCK, HOLDLOCK)
            WHERE g.MovementId = @Id AND g.IsAuto = 1 AND g.Status = 1;

            IF EXISTS (SELECT 1 FROM @AutoDrafts)
            BEGIN
                DELETE m FROM purchase.GoodsReceiptInvoiceMatches m
                INNER JOIN purchase.GoodsReceiptLines l ON l.Id = m.GoodsReceiptLineId
                INNER JOIN @AutoDrafts d                ON d.Id = l.GoodsReceiptId;
                DELETE f FROM purchase.GoodsReceiptFiles f INNER JOIN @AutoDrafts d ON d.Id = f.GoodsReceiptId;
                DELETE l FROM purchase.GoodsReceiptLines l INNER JOIN @AutoDrafts d ON d.Id = l.GoodsReceiptId;
                DELETE a FROM purchase.GoodsReceiptAudit a INNER JOIN @AutoDrafts d ON d.Id = a.GoodsReceiptId;
                DELETE g FROM purchase.GoodsReceipts g INNER JOIN @AutoDrafts d ON d.Id = g.Id;

                INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
                SELECT d.ContainerId, N'Event', LEFT(N'Draft goods receipt removed: movement ' + @MovementNo + N' cancelled', 500), @UserId
                FROM @AutoDrafts d;
            END
        END

        DECLARE @Cid INT;
        DECLARE ctn CURSOR LOCAL FAST_FORWARD FOR SELECT ContainerId FROM logistics.MovementContainers WHERE MovementId = @Id;
        OPEN ctn;
        FETCH NEXT FROM ctn INTO @Cid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_RefreshStatus @Cid;
            FETCH NEXT FROM ctn INTO @Cid;
        END
        CLOSE ctn;
        DEALLOCATE ctn;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO


/* ================================================================== 11. Check */

-- The logistics to-do list: how many containers still travelling stand at each next step.
SELECT NextStep = n.Kind, Containers = COUNT(*)
FROM logistics.Containers c
CROSS APPLY logistics.fn_Container_NextStep(c.Id) n
WHERE c.Status BETWEEN 1 AND 5
GROUP BY n.Kind
ORDER BY COUNT(*) DESC;

-- The usual next legs the history proposes today, per place and last stage (seen at least twice in 365 days).
SELECT Place = p.PortName, g.LastStage, NextLeg = t.TypeName + N' ' + NCHAR(8594) + N' ' + tp.PortName, h.Legs
FROM (SELECT DISTINCT m.ToPlaceId AS PlaceId, mt.Stage AS LastStage
      FROM logistics.Movements m
      INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
      WHERE m.Status = 3) g
CROSS APPLY logistics.fn_Movement_NextLegHistory(g.PlaceId, g.LastStage) h
INNER JOIN masterdata.Ports p          ON p.Id = g.PlaceId
INNER JOIN masterdata.MovementTypes t  ON t.Id = h.MovementTypeId
INNER JOIN masterdata.Ports tp         ON tp.Id = h.ToPlaceId
ORDER BY p.PortName, g.LastStage;

-- Movements that are not the last leg of one of their containers: Cancel now refuses them (rule 10).
SELECT m.MovementNo, Containers = COUNT(DISTINCT mc.ContainerId)
FROM logistics.Movements m
INNER JOIN logistics.MovementContainers mc ON mc.MovementId = m.Id
WHERE m.Status <> 4
  AND EXISTS (SELECT 1 FROM logistics.MovementContainers lc
              INNER JOIN logistics.Movements l ON l.Id = lc.MovementId
              WHERE lc.ContainerId = mc.ContainerId AND l.Id > m.Id AND l.Status <> 4)
GROUP BY m.MovementNo
ORDER BY m.MovementNo;

PRINT 'Script 81 applied: the next step of a container - its step, the usual next leg proposed, many containers grouped by step, a new leg for a group (one movement or one per container), the Next step filter, only the last leg cancelled.';
GO
