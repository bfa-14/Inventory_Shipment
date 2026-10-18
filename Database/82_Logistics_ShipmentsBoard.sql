SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 82: LOGISTICS - THE SHIPMENTS BOARD AND A MOVEMENT THAT ARRIVES IN PARTS (shipment, phase 3)

   The owner's words: "in the containers the shipment is not flexible for the user ... make shipment more user friendly
   and flexible." Phases 1 and 2 (scripts 80, 81) gave every container its next step. Phase 3 shows where every container
   is, by stage, and lets only part of a movement arrive. Movements stay the only record: each container still has one
   real MOV for each leg, with its own dates.

     1. Tables: logistics.Movements.SplitFromMovementId (the movement a split-off movement came from) and
        logistics.MovementAudit (what happened to a movement beyond its own stamps: "Split off into MOV-...", "Split
        from MOV-..."). Both come before the procedures that read them, so a brand-new empty database builds.
     2. The permission containers.shipments.view "View Shipments" (Logistics › Shipments), granted ONCE, when it is first
        created, to the roles that hold View Movements, View Tracking or Manage Shipment Movements (script 75's pattern).
     3. NEW logistics.fn_Container_BoardPhase: THE ONE PLACE where a container's column of the board is decided, from what
        the caller already read of it (fn_Container_ShipState, fn_Container_ReceivedBy), the first that applies:
          Received        received (a posted goods receipt, or offloaded before goods receipts): Offloaded or Closed
          AtSupplier      a Loading at the supplier in progress
          AtSea           the leg in progress is a Sea leg, or a transshipment between two sea ports (a vessel leg, as
                          usp_Movement_AddLeg says it: the Transit stage, not INLAND, from a sea port to a sea port)
          AtPort          a Port stay in progress
          AtBorderCustoms a Customs clearance in progress
          OnTheRoad       any other leg in progress: inland transport, a border crossing, a delivery
          Delivered       no leg in progress, and a draft goods receipt waits or its last completed leg is a Delivery
          AtSupplier      no leg started or completed (planned legs do not move a container)
          AtPort          its last completed leg ends at a sea port (masterdata.Ports.Kind 'Sea')
          AtBorderCustoms its last completed leg ends at a border post or an inland place (any other kind)
        A leg in progress decides first, as in fn_Container_NextStepKind (Complete before OpenReceipt).
     4. NEW logistics.usp_Shipment_Board: one row per container on the board (statuses 1-5, and with @ShowReceived those
        received in the last 30 days; never a cancelled one), with its card (ref, number, type, items, supplier and
        order, the leg or the place, Late, Free time over, the planned next leg, its next step and proposed leg in the
        words of phase 2), its column and its group in the column; a second result set with the containers and pieces
        of each column. Filters: search (ref, container no., B/L, vessel or truck, purchase order number), supplier,
        purchase order, branch, place, late only, with a planned leg. No paging. Worked out set-based for the board's
        rows only (the ship state of each, the planned movement's refusal once per movement, the usual next leg once per
        place and last stage): never a function over every container per row.
     5. NEW logistics.usp_Movement_SplitContainers: ONLY PART OF A MOVEMENT ARRIVED. The ticked containers of a movement in
        progress get their own movement - a copy of the original (type, From, To, planned and start date, ETA, carrier,
        vehicle or vessel, voyage, reference, notes; its own MOV number), in progress - with their rows of the movement's
        container list, their charges filed under the movement and their documents filed under it (a file several
        containers share keeps its other records where they are). Statuses and dates do not change: they travel already.
        The completion that follows (the API's, the only place that drafts a Delivery's goods receipts) is checked FIRST
        (@CompleteDate: not in the future, not before the start), so a refused date splits nothing. Refused:
          70010 "Only a movement in progress can be split: MOV-2026-000046 is completed."
          70010 "Every container of MOV-2026-000046 is ticked: complete the movement itself."
          70010 "KTG-2026-0031 already has the next leg MOV-2026-000051 planned: complete MOV-2026-000046 for every
                container, or take it off MOV-2026-000051 first." (a later leg: "previous" stays "the highest Id below")
          70000 a container not on the movement, none ticked, a completion date in the future or before the start
          70004 the movement was changed by another user;  70006 not found
        Audit on both movements (logistics.MovementAudit) and on each container moved.
     6. logistics.usp_Container_NextStepPreview: + whether each container can be split off its movement in progress and
        why not (CanSplitOff, SplitOffBlockedReason; set 1), and whether a Complete group can complete only the ticked
        (SplitPossible, SplitBlockedReason; set 2): the dialogs offer "Only KTG-2026-0031" with the server's reason.
     7. logistics.usp_Movement_Get: + the movement it was split from (header), whether each of its containers can be split
        off and why not (set 2: the movement page's "Only some containers arrived"), and its history (set 5).
     8. C2. THE CONTAINER PAGE'S ESTIMATE FOLLOWS THE COST RULE (purchase.fn_GoodsReceiptLine_TargetCost, script 79): NEW
        logistics.fn_ContainerLine_FobEstimate - the pieces of a container line covered by invoices that change item
        costs at their price, every other piece (not invoiced, or invoiced by an invoice that does not change item costs)
        at the order price. usp_Container_Get reads it for the FOB total (set 1) and each line's FOB, source and landed
        cost (set 2). A received line keeps its final cost.

   Re-created from their current bodies: logistics.usp_Container_NextStepPreview (81), logistics.usp_Movement_Get (80),
   logistics.usp_Container_Get (81).
   New: the column logistics.Movements.SplitFromMovementId, the table logistics.MovementAudit, the permission
   containers.shipments.view, logistics.fn_Container_BoardPhase, logistics.usp_Shipment_Board,
   logistics.usp_Movement_SplitContainers, logistics.fn_ContainerLine_FobEstimate.
   No new error number: 70000, 70004, 70006, 70010.

   Requires script 81 (Schema.sql runs it first). Idempotent, additive: re-applied at every API start-up, and builds a
   brand-new empty database.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'logistics.fn_Container_NextStep') IS NULL                        -- 81
   OR OBJECT_ID(N'logistics.usp_Container_NextStepPreview', N'P') IS NULL         -- 81
   OR OBJECT_ID(N'logistics.usp_Movement_AddLeg', N'P') IS NULL                   -- 81
    THROW 70000, 'Script 82 requires script 81: apply it first.', 1;
GO

/* ================================================================== 1. A movement split off another, and its history */

-- THE MOVEMENT A SPLIT-OFF MOVEMENT CAME FROM (usp_Movement_SplitContainers): its page says "Split from MOV-...".
IF COL_LENGTH(N'logistics.Movements', N'SplitFromMovementId') IS NULL
BEGIN
    ALTER TABLE logistics.Movements ADD SplitFromMovementId INT NULL;
    PRINT 'Movements: added SplitFromMovementId';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Movements_SplitFrom')
    ALTER TABLE logistics.Movements
        ADD CONSTRAINT FK_Movements_SplitFrom FOREIGN KEY (SplitFromMovementId) REFERENCES logistics.Movements (Id);
GO

-- WHAT HAPPENED TO A MOVEMENT beyond its own stamps (created, started, completed, cancelled): a split, on both movements.
IF OBJECT_ID(N'logistics.MovementAudit', N'U') IS NULL
BEGIN
    CREATE TABLE logistics.MovementAudit
    (
        Id         INT IDENTITY(1,1) NOT NULL,
        MovementId INT            NOT NULL,
        Action     NVARCHAR(30)   NOT NULL,        -- Split off (the original) | Split from (the copy)
        Details    NVARCHAR(1000) NULL,
        UserId     INT            NULL,
        AtUtc      DATETIME2(3)   NOT NULL CONSTRAINT DF_MovementAudit_AtUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_MovementAudit PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_MovementAudit_Movement FOREIGN KEY (MovementId) REFERENCES logistics.Movements (Id),
        CONSTRAINT FK_MovementAudit_User     FOREIGN KEY (UserId)     REFERENCES security.Users (Id)
    );
    CREATE NONCLUSTERED INDEX IX_MovementAudit_Movement ON logistics.MovementAudit (MovementId, AtUtc);
    PRINT 'Created logistics.MovementAudit';
END
GO

/* ================================================================== 2. The permission of the board */

-- Logistics › Shipments is a screen of its own. GRANTED ONCE, when it is first created, to every role that holds what
-- the logistics screens of today need (View Movements, View Tracking, Manage Shipment Movements), so nobody loses
-- anything the day this runs; untick it on Role Permissions afterwards. A role unticked later is never re-granted. The
-- start-up sync of the catalog keeps it (and gives it to the system roles). Name, description and sort order are the
-- catalog's (PermissionCatalog.cs), so the sync changes nothing.
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @Changed TABLE (Action NVARCHAR(10) NOT NULL, PermissionId INT NOT NULL, Code NVARCHAR(100) NOT NULL);

    MERGE security.Permissions AS target
    USING
    (
        VALUES
            (N'containers.shipments.view', N'View Shipments', N'Containers',
             N'Logistics ' + NCHAR(8250) + N' Shipments: the containers on their way, by stage.', 1406)
    ) AS source (Code, Name, Module, Description, SortOrder)
    ON target.Code = source.Code
    WHEN MATCHED AND (target.Name <> source.Name OR target.Module <> source.Module
                      OR ISNULL(target.Description, N'') <> source.Description OR target.SortOrder <> source.SortOrder) THEN
        UPDATE SET Name = source.Name, Module = source.Module, Description = source.Description, SortOrder = source.SortOrder
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (Code, Name, Module, Description, SortOrder)
        VALUES (source.Code, source.Name, source.Module, source.Description, source.SortOrder)
    OUTPUT $action, inserted.Id, inserted.Code INTO @Changed (Action, PermissionId, Code);

    IF EXISTS (SELECT 1 FROM @Changed WHERE Action = N'INSERT')
    BEGIN
        DECLARE @From TABLE (Code NVARCHAR(100) NOT NULL, FromCode NVARCHAR(100) NOT NULL);
        INSERT INTO @From (Code, FromCode) VALUES
            (N'containers.shipments.view', N'containers.movements.view'),
            (N'containers.shipments.view', N'containers.tracking.view'),
            (N'containers.shipments.view', N'containers.movements.manage');

        INSERT INTO security.RolePermissions (RoleId, PermissionId)
        SELECT DISTINCT r.Id, c.PermissionId
        FROM @Changed c
        INNER JOIN @From f ON f.Code = c.Code
        CROSS JOIN security.Roles r
        WHERE c.Action = N'INSERT'
          AND (r.IsSystem = 1
               OR EXISTS (SELECT 1 FROM security.RolePermissions rp INNER JOIN security.Permissions p ON p.Id = rp.PermissionId
                          WHERE rp.RoleId = r.Id AND p.Code = f.FromCode))
          AND NOT EXISTS (SELECT 1 FROM security.RolePermissions rp WHERE rp.RoleId = r.Id AND rp.PermissionId = c.PermissionId);

        DECLARE @Grants INT = @@ROWCOUNT;
        PRINT 'Permission containers.shipments.view created, granted once: ' + CAST(@Grants AS NVARCHAR(10)) + ' role grant(s).';
    END

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO

/* ================================================================== 3. The column of a container on the board */

-- One row: the column of the Shipments board a container stands in, from what the caller already read of it - its
-- status, its open goods receipt (fn_Container_ReceivedBy), the leg in progress carrying it (its stage, type code and the
-- kinds of its From and To) and its last completed leg (stage, kind of its To; NULL = it never moved). The first that
-- applies (see the header): a leg in progress decides first, as in fn_Container_NextStepKind. NULL for a cancelled
-- container: it is never on the board. PhaseOrder is the column's place, left to right.
CREATE OR ALTER FUNCTION logistics.fn_Container_BoardPhase
(
    @Status             TINYINT,
    @GoodsReceiptStatus TINYINT,
    @ActiveStage        NVARCHAR(10),
    @ActiveTypeCode     NVARCHAR(10),
    @ActiveFromKind     NVARCHAR(10),
    @ActiveToKind       NVARCHAR(10),
    @LastStage          NVARCHAR(10),
    @LastToKind         NVARCHAR(10)
)
RETURNS TABLE
AS
RETURN
SELECT p.Phase,
       PhaseOrder = CASE p.Phase WHEN N'AtSupplier' THEN 1 WHEN N'AtSea' THEN 2 WHEN N'AtPort' THEN 3 WHEN N'OnTheRoad' THEN 4
                                 WHEN N'AtBorderCustoms' THEN 5 WHEN N'Delivered' THEN 6 WHEN N'Received' THEN 7 END
FROM (SELECT Phase = CAST(CASE
          WHEN @Status IS NULL OR @Status = 8 THEN NULL
          WHEN @Status IN (6, 7) THEN N'Received'
          WHEN @ActiveStage = N'Origin' THEN N'AtSupplier'
          -- a vessel leg: sea freight, or a transshipment between two sea ports (feeder vessel, not inland transport)
          WHEN @ActiveStage = N'Sea'
               OR (@ActiveStage = N'Transit' AND ISNULL(@ActiveTypeCode, N'') <> N'INLAND'
                   AND @ActiveFromKind = N'Sea' AND @ActiveToKind = N'Sea') THEN N'AtSea'
          WHEN @ActiveStage = N'Port' THEN N'AtPort'
          WHEN @ActiveStage = N'Customs' THEN N'AtBorderCustoms'
          WHEN @ActiveStage IS NOT NULL THEN N'OnTheRoad'                 -- inland transport, a border crossing, a delivery
          WHEN @GoodsReceiptStatus = 1 THEN N'Delivered'                  -- a draft goods receipt waits
          WHEN @LastStage IS NULL THEN N'AtSupplier'                      -- never started a leg
          WHEN @LastStage = N'Delivery' THEN N'Delivered'
          WHEN @LastToKind = N'Sea' THEN N'AtPort'
          ELSE N'AtBorderCustoms' END AS NVARCHAR(16))) p;
GO

/* ================================================================== 4. The Shipments board */

-- Logistics › Shipments: one row per container on the board, with its card, its column (fn_Container_BoardPhase) and its
-- group in the column; then the containers and pieces of each column (the columns of the board, left to right, Received
-- only with @ShowReceived). The filters are the server's; NO PAGING (the board shows every container on its way).
-- Groups in a column (GroupKey, GroupLabel; GroupOrder = their order in the column):
--   At supplier      by port of loading ("Chennai"; "No port of loading")
--   At sea           by movement ("MOV-2026-000046 · MSC Aurora V.123 · Chennai → Dar es Salaam · ETA 20/10/2026")
--   On the road      by leg, From → To ("Dar es Salaam → Kasumbalesa"): trucks travel one movement per container; a
--                    border crossing (a stay) by its place ("Border crossing at Kasumbalesa")
--   At port, At border / customs   by place
--   Delivered, to receive          by the place delivered to
--   Received         by the warehouse received into
-- Card: AtPlace* = where it stands (none while a leg carries it); IsLate = the leg in progress has an ETA before today;
-- IsFreeTimeOver = the rule of the container page, the Tracking board and the Dashboard (at port or cleared, the last free
-- day passed before the end of its Delivery, else before today); the ship state, next step and proposed leg in the
-- columns and words of usp_Container_Search (81). Movement numbers are always given: the page links them for readers who
-- may open movements.
-- SET-BASED FOR THE BOARD'S ROWS ONLY: the containers are found first (each filter a step of its own), then their ship
-- state (the definitions of fn_Container_ShipState, over their movements read once), the planned movement's refusal once
-- per movement, and the usual next leg once per (place, last stage) - never a function over every container per row.
-- Measured on 5,000 open containers in a database of 50,000 (21,200 movements in the last 365 days): about 1.6 s, two
-- thirds of it the usual next leg (fn_Movement_NextLegHistory, phase 2's, read once per pair).
CREATE OR ALTER PROCEDURE logistics.usp_Shipment_Board
    @Search          NVARCHAR(100) = NULL,   -- ref, container no., B/L, vessel or truck, purchase order number
    @SupplierId      INT           = NULL,
    @PurchaseOrderId INT           = NULL,   -- containers carrying lines of this order
    @BranchId        INT           = NULL,
    @PlaceId         INT           = NULL,   -- where it stands, or the From / To of the leg carrying it
    @LateOnly        BIT           = 0,      -- the leg in progress has an ETA before today
    @WithPlannedLeg  BIT           = 0,      -- a planned next leg holds it
    @ShowReceived    BIT           = 0,      -- + the containers received in the last @ReceivedDays days (read-only)
    @ReceivedDays    INT           = 30
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @LateOnly = ISNULL(@LateOnly, 0);
    SET @WithPlannedLeg = ISNULL(@WithPlannedLeg, 0);
    SET @ShowReceived = ISNULL(@ShowReceived, 0);
    IF @ReceivedDays IS NULL OR @ReceivedDays < 1 SET @ReceivedDays = 30;
    IF @ReceivedDays > 366 SET @ReceivedDays = 366;
    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @ReceivedFrom DATE = DATEADD(DAY, -@ReceivedDays, @Today);

    -- 1. THE CONTAINERS ON THE BOARD: Draft to Cleared, and with the switch the ones received lately (the Tracking board's
    -- rule: offloaded on or after the date); then the filters, each a set-based step over those (an OR of searches over
    -- 50,000 containers took 28 s).
    CREATE TABLE #C (Id INT NOT NULL PRIMARY KEY, Status TINYINT NOT NULL);
    INSERT INTO #C (Id, Status)
    SELECT c.Id, c.Status
    FROM logistics.Containers c
    WHERE (c.Status BETWEEN 1 AND 5 OR (@ShowReceived = 1 AND c.Status IN (6, 7) AND c.OffloadedDate >= @ReceivedFrom))
      AND (@BranchId IS NULL OR c.BranchId = @BranchId)
    OPTION (RECOMPILE);

    -- the search: the container's ref, number, B/L or vessel, the number of an order on it, or the vessel or truck of the
    -- leg carrying it
    IF @Search IS NOT NULL
    BEGIN
        DECLARE @Like NVARCHAR(110) = N'%' + @Search + N'%';
        SELECT x.Id
        INTO #Found
        FROM #C x
        INNER JOIN logistics.Containers c ON c.Id = x.Id
        WHERE c.ContainerRef LIKE @Like OR c.ContainerNo LIKE @Like OR c.BlNo LIKE @Like OR c.VesselName LIKE @Like
        UNION
        SELECT x.Id
        FROM #C x
        INNER JOIN logistics.ContainerLines cl  ON cl.ContainerId = x.Id
        INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
        WHERE d.DocumentNumber LIKE @Like
        UNION
        SELECT x.Id
        FROM #C x
        INNER JOIN logistics.MovementContainers mc ON mc.ContainerId = x.Id
        INNER JOIN logistics.Movements m           ON m.Id = mc.MovementId AND m.Status = 2
        WHERE m.VehicleOrVessel LIKE @Like;

        DELETE x FROM #C x WHERE NOT EXISTS (SELECT 1 FROM #Found f WHERE f.Id = x.Id);
    END

    IF @SupplierId IS NOT NULL
        DELETE x
        FROM #C x
        WHERE NOT EXISTS (SELECT 1
                          FROM logistics.ContainerLines cl
                          INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                          WHERE cl.ContainerId = x.Id AND d.SupplierId = @SupplierId);

    IF @PurchaseOrderId IS NOT NULL
        DELETE x
        FROM #C x
        WHERE NOT EXISTS (SELECT 1 FROM logistics.ContainerLines cl WHERE cl.ContainerId = x.Id AND cl.PurchaseOrderId = @PurchaseOrderId);

    -- 2. WHERE EACH STANDS: the definitions of fn_Container_ShipState (phase 1), worked out SET-BASED over the movements of
    -- the board's containers, read once: its movements not cancelled, the latest of them (where its next leg leaves from),
    -- the one in progress, its next planned one (the lowest Id above the latest it started or made), its last completed
    -- one; and its latest completed Delivery (fn_Container_LastDelivery's order). Read through the functions for each
    -- container, the same took seconds on 5,000 containers.
    SELECT mc.ContainerId, MovementId = m.Id, m.Status, m.MovementTypeId, m.ToPlaceId, m.EndDate, m.CompletedAtUtc
    INTO #M
    FROM #C x
    INNER JOIN logistics.MovementContainers mc ON mc.ContainerId = x.Id
    INNER JOIN logistics.Movements m           ON m.Id = mc.MovementId AND m.Status <> 4;
    CREATE CLUSTERED INDEX IX_M ON #M (ContainerId, MovementId);

    SELECT x.Id, MovementCount = COUNT(m.MovementId), LatestId = MAX(m.MovementId),
           ActiveId = MAX(CASE WHEN m.Status = 2 THEN m.MovementId END),
           StartedMaxId = MAX(CASE WHEN m.Status IN (2, 3) THEN m.MovementId END),
           LastCompletedId = MAX(CASE WHEN m.Status = 3 THEN m.MovementId END)
    INTO #Ms
    FROM #C x
    LEFT JOIN #M m ON m.ContainerId = x.Id
    GROUP BY x.Id;

    SELECT s.Id, s.MovementCount, s.LatestId, s.ActiveId, s.LastCompletedId, PlannedId = pn.PlannedId,
           LastDeliveryId = ld.MovementId
    INTO #Sh
    FROM #Ms s
    LEFT JOIN (SELECT m.ContainerId, PlannedId = MIN(m.MovementId)
               FROM #M m
               INNER JOIN #Ms x ON x.Id = m.ContainerId
               WHERE m.Status = 1 AND m.MovementId > ISNULL(x.StartedMaxId, 0)
               GROUP BY m.ContainerId) pn ON pn.ContainerId = s.Id
    LEFT JOIN (SELECT m.ContainerId, m.MovementId,
                      Seq = ROW_NUMBER() OVER (PARTITION BY m.ContainerId
                                               ORDER BY m.EndDate DESC, m.CompletedAtUtc DESC, m.MovementId DESC)
               FROM #M m
               INNER JOIN masterdata.MovementTypes t ON t.Id = m.MovementTypeId AND t.Stage = N'Delivery'
               WHERE m.Status = 3) ld ON ld.ContainerId = s.Id AND ld.Seq = 1;

    -- the movements they name, once each, with how many containers each carries
    SELECT v.Id, m.MovementNo, m.Status, m.MovementTypeId, TypeCode = mt.TypeCode, TypeName = mt.TypeName, mt.Stage,
           m.FromPlaceId, FromName = fp.PortName, FromKind = fp.Kind, m.ToPlaceId, ToName = tp.PortName, ToKind = tp.Kind,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.VehicleOrVessel, m.VoyageNo, CarrierName = cp.PartyName,
           Cnt = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = v.Id)
    INTO #Mv
    FROM (SELECT Id = ActiveId FROM #Sh WHERE ActiveId IS NOT NULL
          UNION SELECT PlannedId FROM #Sh WHERE PlannedId IS NOT NULL
          UNION SELECT LatestId FROM #Sh WHERE LatestId IS NOT NULL
          UNION SELECT LastCompletedId FROM #Sh WHERE LastCompletedId IS NOT NULL
          UNION SELECT LastDeliveryId FROM #Sh WHERE LastDeliveryId IS NOT NULL) v
    INNER JOIN logistics.Movements m       ON m.Id = v.Id
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId;
    CREATE UNIQUE CLUSTERED INDEX IX_Mv ON #Mv (Id);

    -- who received it and its open goods receipt (fn_Container_ReceivedBy, the only test for "offloaded before goods
    -- receipts"), read for the containers that have an open goods receipt or are received: for any other it says nothing
    -- (NULL), and read for 5,000 rows it cost a spool of every container
    SELECT x.Id
    INTO #Rc
    FROM #C x
    WHERE x.Status IN (6, 7)
       OR EXISTS (SELECT 1 FROM purchase.GoodsReceipts g WHERE g.ContainerId = x.Id AND g.Status < 3);

    SELECT x.Id, rb.ReceivedBy, rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus
    INTO #Rb
    FROM #Rc x
    CROSS APPLY logistics.fn_Container_ReceivedBy(x.Id) rb;

    SELECT c.Id, c.ContainerRef, c.ContainerNo, ContainerTypeCode = ct.TypeCode, c.Status, c.BranchId, BranchCode = b.BranchCode,
           c.PurchaseOrderId, PurchaseOrderNumber = mpo.DocumentNumber,
           c.PortOfLoadingId, PortOfLoadingName = pl.PortName, c.PortOfDestinationId, PortOfDestinationName = pd.PortName,
           c.FinalDestinationId, FinalDestinationName = fd.PortName,
           c.VesselName, c.VoyageNo, c.BlNo, c.Eta, c.LastFreeDay, c.OffloadedDate, c.WarehouseId,
           -- fn_Container_ShipState's columns
           sh.MovementCount,
           PlaceId = CASE WHEN lm.Id IS NULL THEN c.PortOfLoadingId ELSE lm.ToPlaceId END,
           PlaceName = CASE WHEN lm.Id IS NULL THEN pl.PortName ELSE lm.ToName END,
           PlaceSince = CASE WHEN lm.Status = 3 THEN lm.EndDate END,
           ActiveMovementId = am.Id, ActiveMovementNo = am.MovementNo, ActiveMovementTypeName = am.TypeName,
           ActiveMovementStage = am.Stage, ActiveMovementFromName = am.FromName, ActiveMovementToName = am.ToName,
           ActiveMovementStartDate = am.StartDate, ActiveMovementEta = am.Eta, ActiveMovementContainerCount = am.Cnt,
           ActiveMovementFromPlaceId = am.FromPlaceId, ActiveMovementToPlaceId = am.ToPlaceId,
           ActiveMovementTypeCode = am.TypeCode, ActiveFromKind = am.FromKind, ActiveToKind = am.ToKind,
           ActiveMovementVehicleOrVessel = am.VehicleOrVessel, ActiveMovementVoyageNo = am.VoyageNo,
           ActiveMovementCarrierName = am.CarrierName,
           PlannedMovementId = np.Id, PlannedMovementNo = np.MovementNo, PlannedMovementTypeName = np.TypeName,
           PlannedMovementStage = np.Stage, PlannedMovementFromName = np.FromName, PlannedMovementToName = np.ToName,
           PlannedMovementDate = np.PlannedDate, PlannedMovementContainerCount = np.Cnt,
           LastMovementId = lc.Id, LastMovementNo = lc.MovementNo, LastMovementEndDate = lc.EndDate,
           LastStage = lc.Stage, LastToPlaceId = lc.ToPlaceId, LastToName = lc.ToName, LastToKind = lc.ToKind,
           rb.ReceivedBy, rb.GoodsReceiptId, rb.GoodsReceiptNumber, rb.GoodsReceiptStatus,
           LastDeliveryMovementId = dl.Id, DeliveredDate = dl.EndDate, DeliveryPlaceId = dl.ToPlaceId,
           DeliveryPlaceName = dl.ToName
    INTO #B
    FROM #Sh sh
    LEFT  JOIN #Rb rb                       ON rb.Id = sh.Id
    INNER JOIN logistics.Containers c       ON c.Id = sh.Id
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN masterdata.Ports fd          ON fd.Id = c.FinalDestinationId
    LEFT  JOIN purchase.PurchaseDocuments mpo ON mpo.Id = c.PurchaseOrderId
    LEFT  JOIN #Mv lm ON lm.Id = sh.LatestId
    LEFT  JOIN #Mv am ON am.Id = sh.ActiveId
    LEFT  JOIN #Mv np ON np.Id = sh.PlannedId
    LEFT  JOIN #Mv lc ON lc.Id = sh.LastCompletedId
    LEFT  JOIN #Mv dl ON dl.Id = sh.LastDeliveryId;
    CREATE UNIQUE CLUSTERED INDEX IX_B ON #B (Id);

    -- why a planned movement cannot start yet, once per movement (fn_Movement_StartBlock: read through each row's ship
    -- state it cost seconds)
    SELECT p.MovementId, sb.Reason, sb.StartNotBefore
    INTO #Sb
    FROM (SELECT DISTINCT MovementId = PlannedMovementId FROM #B WHERE PlannedMovementId IS NOT NULL) p
    CROSS APPLY logistics.fn_Movement_StartBlock(p.MovementId) sb;

    -- 3. ITS NEXT STEP (fn_Container_NextStepKind) AND ITS COLUMN (fn_Container_BoardPhase), then the place it stands at
    -- (the steps below keep only what they add: the card is put together once, at the end)
    SELECT b.Id, PlannedMovementBlockedReason = sb.Reason, PlannedMovementNotBefore = sb.StartNotBefore,
           NextStepKind = nk.Kind, NextStepBlockedReason = nk.BlockedReason, ph.Phase, ph.PhaseOrder,
           IsLate = CAST(CASE WHEN b.ActiveMovementEta < @Today THEN 1 ELSE 0 END AS BIT),
           IsFreeTimeOver = CAST(CASE WHEN b.Status IN (4, 5) AND b.LastFreeDay IS NOT NULL
                                           AND b.LastFreeDay < ISNULL(b.DeliveredDate, @Today) THEN 1 ELSE 0 END AS BIT),
           AtPlaceId = CASE ph.Phase WHEN N'AtSupplier' THEN b.PortOfLoadingId
                                     WHEN N'AtPort' THEN COALESCE(b.ActiveMovementToPlaceId, b.LastToPlaceId)
                                     WHEN N'AtBorderCustoms' THEN COALESCE(b.ActiveMovementToPlaceId, b.LastToPlaceId)
                                     WHEN N'Delivered' THEN COALESCE(b.DeliveryPlaceId, b.LastToPlaceId, b.PortOfLoadingId) END,
           AtPlaceName = CASE ph.Phase WHEN N'AtSupplier' THEN b.PortOfLoadingName
                                       WHEN N'AtPort' THEN COALESCE(b.ActiveMovementToName, b.LastToName)
                                       WHEN N'AtBorderCustoms' THEN COALESCE(b.ActiveMovementToName, b.LastToName)
                                       WHEN N'Delivered' THEN COALESCE(b.DeliveryPlaceName, b.LastToName, b.PortOfLoadingName) END,
           -- since when: a stay in progress since its start, else the end of the leg that brought it, the delivery, the receipt
           AtPlaceSince = CASE WHEN ph.Phase IN (N'AtPort', N'AtBorderCustoms') AND b.ActiveMovementId IS NOT NULL THEN b.ActiveMovementStartDate
                               WHEN ph.Phase IN (N'AtPort', N'AtBorderCustoms') THEN b.LastMovementEndDate
                               WHEN ph.Phase = N'Delivered' THEN COALESCE(b.DeliveredDate, b.LastMovementEndDate)
                               WHEN ph.Phase = N'Received' THEN b.OffloadedDate END
    INTO #S
    FROM #B b
    LEFT JOIN #Sb sb ON sb.MovementId = b.PlannedMovementId
    CROSS APPLY logistics.fn_Container_NextStepKind(b.Id, b.Status, b.MovementCount, b.ActiveMovementId, b.PlannedMovementId,
                                                    sb.Reason, b.LastMovementId, b.LastDeliveryMovementId,
                                                    b.GoodsReceiptStatus) nk
    CROSS APPLY logistics.fn_Container_BoardPhase(b.Status, b.GoodsReceiptStatus, b.ActiveMovementStage, b.ActiveMovementTypeCode,
                                                  b.ActiveFromKind, b.ActiveToKind,
                                                  CASE WHEN b.LastMovementId IS NULL THEN NULL ELSE b.LastStage END,
                                                  b.LastToKind) ph
    WHERE ph.Phase IS NOT NULL;
    CREATE UNIQUE CLUSTERED INDEX IX_S ON #S (Id);

    -- the filters that read where it stands (place, late, planned leg)
    IF @PlaceId IS NOT NULL OR @LateOnly = 1 OR @WithPlannedLeg = 1
        DELETE s
        FROM #S s
        INNER JOIN #B b ON b.Id = s.Id
        WHERE (@PlaceId IS NOT NULL AND ISNULL(s.AtPlaceId, 0) <> @PlaceId AND ISNULL(b.ActiveMovementFromPlaceId, 0) <> @PlaceId
               AND ISNULL(b.ActiveMovementToPlaceId, 0) <> @PlaceId)
           OR (@LateOnly = 1 AND s.IsLate = 0)
           OR (@WithPlannedLeg = 1 AND b.PlannedMovementId IS NULL);

    -- the warehouse a received container went into: its posted goods receipt's, else (an offload of before) its own
    SELECT s.Id, ReceivedWarehouseId = w.Id, ReceivedWarehouseName = w.WarehouseName
    INTO #Rw
    FROM #S s
    INNER JOIN #B b ON b.Id = s.Id
    LEFT JOIN purchase.GoodsReceipts g    ON g.Id = b.GoodsReceiptId AND b.GoodsReceiptStatus = 2
    INNER JOIN masterdata.Warehouses w    ON w.Id = COALESCE(g.WarehouseId, b.WarehouseId)
    WHERE s.Phase = N'Received';

    -- 4. THE PROPOSED NEXT LEG (Ship, NextLeg: "Inland transport to Kasumbalesa..."), as usp_Container_Search gives it:
    -- the usual leg from a place once per (place, last stage), not once per row.
    SELECT b.Id AS ContainerId, b.PlaceId, LastStage = CASE WHEN b.MovementCount = 0 THEN NULL ELSE b.LastStage END,
           IsCleared = CAST(CASE WHEN b.Status = 5 THEN 1 ELSE 0 END AS BIT),
           b.PortOfDestinationId, b.FinalDestinationId
    INTO #Leg
    FROM #S s
    INNER JOIN #B b ON b.Id = s.Id
    WHERE s.NextStepKind IN (N'Ship', N'NextLeg');

    -- the history of a (place, none) pair only when a container that never moved has no port of destination: with one,
    -- fn_Container_NextLegProposal proposes Sea freight to it and reads no history
    -- (one statement per pair: the same pairs through one CROSS APPLY took half as long again)
    CREATE TABLE #Hist (PlaceId INT NOT NULL, LastStage NVARCHAR(10) NULL, MovementTypeId INT NULL, ToPlaceId INT NULL, Legs INT NULL);
    DECLARE @Pairs TABLE (Seq INT IDENTITY(1, 1) PRIMARY KEY, PlaceId INT NOT NULL, LastStage NVARCHAR(10) NULL);
    INSERT INTO @Pairs (PlaceId, LastStage)
    SELECT DISTINCT PlaceId, LastStage FROM #Leg
    WHERE PlaceId IS NOT NULL AND (LastStage IS NOT NULL OR PortOfDestinationId IS NULL);
    DECLARE @Pair INT = 1, @PairPlaceId INT, @PairStage NVARCHAR(10);
    WHILE EXISTS (SELECT 1 FROM @Pairs WHERE Seq = @Pair)
    BEGIN
        SELECT @PairPlaceId = PlaceId, @PairStage = LastStage FROM @Pairs WHERE Seq = @Pair;
        INSERT INTO #Hist (PlaceId, LastStage, MovementTypeId, ToPlaceId, Legs)
        SELECT @PairPlaceId, @PairStage, h.MovementTypeId, h.ToPlaceId, h.Legs
        FROM logistics.fn_Movement_NextLegHistory(@PairPlaceId, @PairStage) h;
        SET @Pair += 1;
    END

    -- fn_Container_NextLegProposal reads of the container only its port of destination and final destination: the
    -- proposal is worked out once per distinct (place, last stage, cleared, those two ports), for one of its containers
    SELECT d.PlaceId, d.LastStage, d.IsCleared, d.PortOfDestinationId, d.FinalDestinationId,
           pr.TypeId, pr.TypeCode, pr.TypeName, pr.Stage, pr.FromPlaceId, pr.FromName, pr.ToPlaceId, pr.ToName,
           pr.Source, pr.Legs, pr.IsStay
    INTO #Prop
    FROM (SELECT l.PlaceId, l.LastStage, l.IsCleared, l.PortOfDestinationId, l.FinalDestinationId, AnyContainerId = MIN(l.ContainerId)
          FROM #Leg l
          GROUP BY l.PlaceId, l.LastStage, l.IsCleared, l.PortOfDestinationId, l.FinalDestinationId) d
    LEFT JOIN #Hist h ON h.PlaceId = d.PlaceId AND ISNULL(h.LastStage, N'') = ISNULL(d.LastStage, N'')
    OUTER APPLY logistics.fn_Container_NextLegProposal(d.AnyContainerId, d.PlaceId, d.LastStage, d.IsCleared,
                                                       h.MovementTypeId, h.ToPlaceId, h.Legs) pr;

    -- 5. THE ORDERS, SUPPLIERS AND ITEMS of each card (usp_Container_Search's: the first order and supplier + how many more)
    SELECT cl.ContainerId, cl.PurchaseOrderId, cl.ItemId, Qty = SUM(cl.QuantityBase)
    INTO #L1
    FROM #S s
    INNER JOIN logistics.ContainerLines cl ON cl.ContainerId = s.Id
    GROUP BY cl.ContainerId, cl.PurchaseOrderId, cl.ItemId;

    SELECT o.ContainerId, OrderCount = COUNT(*), FirstOrder = MIN(d.DocumentNumber),
           SupplierCount = COUNT(DISTINCT d.SupplierId), FirstSupplier = MIN(sp.PartyName)
    INTO #Lo
    FROM (SELECT DISTINCT ContainerId, PurchaseOrderId FROM #L1) o
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = o.PurchaseOrderId
    INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
    GROUP BY o.ContainerId;

    SELECT x.ContainerId, ItemCount = COUNT(*), Qty = SUM(x.Qty), FirstItemCode = MIN(i.ItemCode), FirstItemName = MIN(i.ItemName)
    INTO #Li
    FROM (SELECT ContainerId, ItemId, Qty = SUM(Qty) FROM #L1 GROUP BY ContainerId, ItemId) x
    INNER JOIN inventory.Items i ON i.Id = x.ItemId
    GROUP BY x.ContainerId;

    -- 6. THE CARDS, in the order of the board: column, group, ref
    SELECT b.Id, b.ContainerRef, b.ContainerNo, b.ContainerTypeCode, b.Status, b.BranchId, b.BranchCode,
           b.PurchaseOrderId, b.PurchaseOrderNumber,
           OrderCount = ISNULL(lo.OrderCount, 0),
           OrderNumbers = CASE WHEN ISNULL(lo.OrderCount, 0) = 0 THEN NULL
                               WHEN lo.OrderCount = 1 THEN lo.FirstOrder
                               ELSE lo.FirstOrder + N' +' + CAST(lo.OrderCount - 1 AS NVARCHAR(10)) END,
           SupplierCount = ISNULL(lo.SupplierCount, 0),
           SupplierNames = CASE WHEN ISNULL(lo.SupplierCount, 0) = 0 THEN NULL
                                WHEN lo.SupplierCount = 1 THEN lo.FirstSupplier
                                ELSE lo.FirstSupplier + N' +' + CAST(lo.SupplierCount - 1 AS NVARCHAR(10)) END,
           ItemCount = ISNULL(li.ItemCount, 0),
           ItemCode = CASE WHEN li.ItemCount = 1 THEN li.FirstItemCode END,
           ItemName = CASE WHEN li.ItemCount = 1 THEN li.FirstItemName END,
           TotalQtyBase = ISNULL(li.Qty, 0),
           b.PortOfLoadingId, b.PortOfLoadingName, b.PortOfDestinationName, b.FinalDestinationName,
           b.VesselName, b.VoyageNo, b.BlNo, b.Eta, b.LastFreeDay, b.OffloadedDate,
           -- the board
           s.Phase, s.PhaseOrder, gk.GroupKey, gk.GroupLabel,
           GroupOrder = DENSE_RANK() OVER (PARTITION BY s.Phase ORDER BY gk.SortNone, gk.SortDate, gk.GroupLabel, gk.GroupKey),
           AtPlaceId = s.AtPlaceId, AtPlaceName = COALESCE(s.AtPlaceName, rw.ReceivedWarehouseName), s.AtPlaceSince,
           s.IsLate, s.IsFreeTimeOver, rw.ReceivedWarehouseId, rw.ReceivedWarehouseName,
           -- the shipment (fn_Container_ShipState), the columns of usp_Container_Search
           b.MovementCount, b.PlaceId, b.PlaceName, b.PlaceSince,
           b.ActiveMovementId, b.ActiveMovementNo, b.ActiveMovementTypeName, b.ActiveMovementStage,
           b.ActiveMovementFromPlaceId, b.ActiveMovementFromName, b.ActiveMovementToPlaceId, b.ActiveMovementToName,
           b.ActiveMovementStartDate, b.ActiveMovementEta, b.ActiveMovementContainerCount,
           b.ActiveMovementVehicleOrVessel, b.ActiveMovementVoyageNo, b.ActiveMovementCarrierName,
           b.PlannedMovementId, b.PlannedMovementNo, b.PlannedMovementTypeName, b.PlannedMovementStage,
           b.PlannedMovementFromName, b.PlannedMovementToName, b.PlannedMovementDate, b.PlannedMovementContainerCount,
           s.PlannedMovementBlockedReason, s.PlannedMovementNotBefore,
           b.LastMovementId, b.LastMovementNo, b.LastMovementEndDate,
           -- the movement in progress, else the last completed one (the list's Movement column)
           CurrentMovementId = COALESCE(b.ActiveMovementId, b.LastMovementId),
           CurrentMovementNo = COALESCE(b.ActiveMovementNo, b.LastMovementNo),
           CurrentMovementStatus = CAST(CASE WHEN b.ActiveMovementId IS NOT NULL THEN 2 WHEN b.LastMovementId IS NOT NULL THEN 3 END AS TINYINT),
           -- its next step and the proposed new leg (fn_Container_NextStepKind, fn_Container_NextLegProposal)
           s.NextStepKind, s.NextStepBlockedReason,
           ProposedTypeId = pr.TypeId, ProposedTypeCode = pr.TypeCode, ProposedTypeName = pr.TypeName, ProposedStage = pr.Stage,
           ProposedFromPlaceId = pr.FromPlaceId, ProposedFromName = pr.FromName,
           ProposedToPlaceId = pr.ToPlaceId, ProposedToName = pr.ToName,
           ProposalSource = pr.Source, ProposalLegs = pr.Legs, ProposedIsStay = pr.IsStay,
           -- goods receipts
           b.ReceivedBy, b.GoodsReceiptId, b.GoodsReceiptNumber, b.GoodsReceiptStatus, b.DeliveredDate, b.DeliveryPlaceName
    FROM #S s
    INNER JOIN #B b ON b.Id = s.Id
    LEFT JOIN #Rw rw ON rw.Id = s.Id
    LEFT JOIN #Leg l ON l.ContainerId = s.Id
    LEFT JOIN #Prop pr ON pr.PlaceId = l.PlaceId AND ISNULL(pr.LastStage, N'') = ISNULL(l.LastStage, N'')
                      AND pr.IsCleared = l.IsCleared AND ISNULL(pr.PortOfDestinationId, 0) = ISNULL(l.PortOfDestinationId, 0)
                      AND ISNULL(pr.FinalDestinationId, 0) = ISNULL(l.FinalDestinationId, 0)
    LEFT JOIN #Lo lo ON lo.ContainerId = s.Id
    LEFT JOIN #Li li ON li.ContainerId = s.Id
    -- the group: its key, its words, and what orders the groups of a column
    CROSS APPLY (SELECT GroupKey = CASE s.Phase
                            WHEN N'AtSea' THEN N'MOV|' + CAST(b.ActiveMovementId AS NVARCHAR(12))
                            WHEN N'OnTheRoad' THEN N'LEG|' + CAST(b.ActiveMovementFromPlaceId AS NVARCHAR(12)) + N'|'
                                                   + CAST(b.ActiveMovementToPlaceId AS NVARCHAR(12))
                            WHEN N'Received' THEN N'WH|' + ISNULL(CAST(rw.ReceivedWarehouseId AS NVARCHAR(12)), N'0')
                            ELSE N'AT|' + ISNULL(CAST(s.AtPlaceId AS NVARCHAR(12)), N'0') END,
                        GroupLabel = CAST(CASE s.Phase
                            WHEN N'AtSea' THEN CONCAT_WS(N' ' + NCHAR(183) + N' ', b.ActiveMovementNo,
                                     NULLIF(CONCAT_WS(N' ', b.ActiveMovementVehicleOrVessel,
                                                      CASE WHEN b.ActiveMovementVoyageNo IS NULL THEN NULL
                                                           WHEN b.ActiveMovementVoyageNo LIKE N'V%' THEN b.ActiveMovementVoyageNo
                                                           ELSE N'V.' + b.ActiveMovementVoyageNo END), N''),
                                     b.ActiveMovementFromName + N' ' + NCHAR(8594) + N' ' + b.ActiveMovementToName,
                                     N'ETA ' + CONVERT(NVARCHAR(10), b.ActiveMovementEta, 103))
                            -- a stay on the road (a border crossing) has no From -> To: "Border crossing at Kasumbalesa"
                            WHEN N'OnTheRoad' THEN CASE WHEN b.ActiveMovementFromPlaceId = b.ActiveMovementToPlaceId
                                                        THEN b.ActiveMovementTypeName + N' at ' + b.ActiveMovementFromName
                                                        ELSE b.ActiveMovementFromName + N' ' + NCHAR(8594) + N' ' + b.ActiveMovementToName END
                            WHEN N'AtSupplier' THEN ISNULL(s.AtPlaceName, N'No port of loading')
                            WHEN N'Received' THEN ISNULL(rw.ReceivedWarehouseName, N'No warehouse')
                            ELSE ISNULL(s.AtPlaceName, N'Place unknown') END AS NVARCHAR(300)),
                        SortNone = CASE WHEN s.Phase = N'Received' AND rw.ReceivedWarehouseId IS NULL THEN 1
                                        WHEN s.Phase NOT IN (N'AtSea', N'OnTheRoad', N'Received') AND s.AtPlaceId IS NULL THEN 1
                                        ELSE 0 END,
                        SortDate = CASE WHEN s.Phase = N'AtSea' THEN ISNULL(b.ActiveMovementEta, '99991231') END) gk
    ORDER BY s.PhaseOrder, GroupOrder, LEN(b.ContainerRef), b.ContainerRef, b.Id;

    -- 7. THE COLUMNS, left to right: their containers and pieces (Received only with the switch)
    SELECT col.Phase, col.Title, col.PhaseOrder, [Count] = ISNULL(n.Containers, 0), Pieces = ISNULL(n.Pieces, 0)
    FROM (VALUES (N'AtSupplier', N'At supplier', 1), (N'AtSea', N'At sea', 2), (N'AtPort', N'At port', 3),
                 (N'OnTheRoad', N'On the road', 4), (N'AtBorderCustoms', N'At border / customs', 5),
                 (N'Delivered', N'Delivered, to receive', 6),
                 (N'Received', N'Received (' + CAST(@ReceivedDays AS NVARCHAR(10)) + N' days)', 7)) col (Phase, Title, PhaseOrder)
    LEFT JOIN (SELECT s.Phase, Containers = COUNT(*), Pieces = SUM(CAST(ISNULL(li.Qty, 0) AS BIGINT))
               FROM #S s
               LEFT JOIN #Li li ON li.ContainerId = s.Id
               GROUP BY s.Phase) n
           ON n.Phase = col.Phase
    WHERE col.Phase <> N'Received' OR @ShowReceived = 1
    ORDER BY col.PhaseOrder;
END
GO

/* ================================================================== 5. Only part of a movement arrived: a split */

-- WHY A CONTAINER CANNOT BE SPLIT OFF ITS MOVEMENT (NULL when it can), from what the caller already has of the movement
-- (its number, status and how many containers it carries): the one place of these words, for the split itself, the next
-- step's dialogs (usp_Container_NextStepPreview) and the movement page (usp_Movement_Get).
--   - only a movement in progress is split ("Only a movement in progress can be split: MOV-... is completed.");
--   - a movement carrying this container alone is completed, not split;
--   - a container that already has a LATER leg (not cancelled) stays: "previous" is the movement with the highest Id
--     below, and the copy gets a higher Id than that later leg - its place would come out wrong.
CREATE OR ALTER FUNCTION logistics.fn_Movement_SplitBlock
(
    @MovementId     INT,
    @MovementNo     NVARCHAR(30),
    @MovementStatus TINYINT,
    @ContainerCount INT,
    @ContainerId    INT,
    @ContainerRef   NVARCHAR(30)
)
RETURNS TABLE
AS
RETURN
SELECT Reason = CAST(CASE
           WHEN ISNULL(@MovementStatus, 0) <> 2
               THEN N'Only a movement in progress can be split: ' + @MovementNo + N' is '
                    + CASE @MovementStatus WHEN 1 THEN N'planned' WHEN 3 THEN N'completed' ELSE N'cancelled' END + N'.'
           WHEN ISNULL(@ContainerCount, 0) <= 1
               THEN @MovementNo + N' carries only ' + @ContainerRef + N': complete the movement itself.'
           WHEN l.MovementNo IS NOT NULL
               THEN @ContainerRef + N' already has the next leg ' + l.MovementNo + N' ' + l.StatusWord + N': complete '
                    + @MovementNo + N' for every container, or take it off ' + l.MovementNo + N' first.' END AS NVARCHAR(400))
FROM (SELECT One = 1) k
OUTER APPLY (SELECT TOP (1) m.MovementNo,
                    StatusWord = CASE m.Status WHEN 1 THEN N'planned' WHEN 2 THEN N'in progress' ELSE N'completed' END
             FROM logistics.MovementContainers lc
             INNER JOIN logistics.Movements m ON m.Id = lc.MovementId
             WHERE lc.ContainerId = @ContainerId AND m.Id > @MovementId AND m.Status <> 4
             ORDER BY m.Id) l;
GO

-- THE CONTAINERS THAT ARRIVED GET THEIR OWN MOVEMENT: a copy of the movement in progress (the same type, From, To,
-- planned and start date, ETA, carrier, vehicle or vessel, voyage, reference and notes, started the same day, its own MOV
-- number, SplitFromMovementId = the original), to which their rows of the movement's container list, their charges filed
-- under the movement and their documents filed under the movement move; the others stay on the original, in progress.
-- The containers' statuses and dates do not change: they travel already, with the same dates.
-- @CompleteDate: the completion that follows (the API completes the copy at once, through the movement's own Complete -
-- the only place that drafts a Delivery's goods receipts after the commit). It is checked FIRST, with Complete's rules
-- (not in the future, not before the start), so a refused date splits nothing. NULL = not checked (a split alone).
-- All the checks run under the movement's lock, in the transaction of the split: one transaction, all or nothing.
-- Audit: on both movements (logistics.MovementAudit), and on each container moved (logistics.ContainerAudit).
-- Returns one row: the new movement (NewId, MovementNo, RowVersion), the original, how many moved and how many stay.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_SplitContainers
    @MovementId   INT,
    @ContainerIds logistics.tvp_IdList READONLY,
    @RowVersion   BINARY(8) = NULL,
    @UserId       INT       = NULL,
    @CompleteDate DATE      = NULL,
    @NewId        INT       = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status TINYINT, @MovementNo NVARCHAR(30), @StartDate DATE, @Count INT, @Left INT, @Msg NVARCHAR(400),
            @Number NVARCHAR(30), @Refs NVARCHAR(1000);
    DECLARE @Ids TABLE (Id INT NOT NULL PRIMARY KEY, ContainerRef NVARCHAR(30) NULL);
    SET @NewId = NULL;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- the movement, locked until the split is committed: nobody completes, cancels or edits it meanwhile
        SELECT @Status = m.Status, @MovementNo = m.MovementNo, @StartDate = m.StartDate
        FROM logistics.Movements m WITH (UPDLOCK, HOLDLOCK)
        WHERE m.Id = @MovementId;

        IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @MovementId AND RowVersion = @RowVersion)
            THROW 70004, 'This movement was modified by another user. Reload the page and try again.', 1;
        IF @Status <> 2
        BEGIN
            SELECT @Msg = b.Reason FROM logistics.fn_Movement_SplitBlock(@MovementId, @MovementNo, @Status, NULL, NULL, NULL) b;
            THROW 70010, @Msg, 1;
        END

        -- THE COMPLETION THAT FOLLOWS, FIRST: Complete's own rules and words (usp_Movement_SetStatus), one day of tolerance
        IF @CompleteDate IS NOT NULL AND @CompleteDate > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
            THROW 70000, 'The end date cannot be in the future: complete the movement on the day it really arrives.', 1;
        IF @CompleteDate IS NOT NULL AND @CompleteDate < @StartDate
            THROW 70000, 'The end date cannot be earlier than the start date.', 1;

        INSERT INTO @Ids (Id, ContainerRef)
        SELECT x.Id, c.ContainerRef FROM @ContainerIds x LEFT JOIN logistics.Containers c ON c.Id = x.Id;
        SET @Count = (SELECT COUNT(*) FROM @Ids);
        IF @Count = 0 THROW 70000, 'Tick the containers that arrived.', 1;

        -- every one is on this movement
        SELECT TOP (1) @Msg = ISNULL(x.ContainerRef, N'Container ' + CAST(x.Id AS NVARCHAR(12))) + N' is not on ' + @MovementNo + N'.'
        FROM @Ids x
        WHERE NOT EXISTS (SELECT 1 FROM logistics.MovementContainers mc WHERE mc.MovementId = @MovementId AND mc.ContainerId = x.Id)
        ORDER BY CASE WHEN x.ContainerRef IS NULL THEN 1 ELSE 0 END, LEN(x.ContainerRef), x.ContainerRef, x.Id;
        IF @Msg IS NOT NULL THROW 70000, @Msg, 1;

        -- not all of them: then the movement itself is completed
        SET @Left = (SELECT COUNT(*) FROM logistics.MovementContainers mc
                     WHERE mc.MovementId = @MovementId AND NOT EXISTS (SELECT 1 FROM @Ids x WHERE x.Id = mc.ContainerId));
        IF @Left = 0
        BEGIN
            SET @Msg = N'Every container of ' + @MovementNo + N' is ticked: complete the movement itself.';
            THROW 70010, @Msg, 1;
        END

        -- none has a later leg (fn_Movement_SplitBlock: the travel order of "the highest Id below" stays true)
        SELECT TOP (1) @Msg = b.Reason
        FROM @Ids x
        CROSS APPLY logistics.fn_Movement_SplitBlock(@MovementId, @MovementNo, @Status, @Count + @Left, x.Id, x.ContainerRef) b
        WHERE b.Reason IS NOT NULL
        ORDER BY LEN(x.ContainerRef), x.ContainerRef;
        IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

        -- 1. THE COPY: the same header and start, in progress, its own number
        EXEC inventory.usp_DocumentType_NextNumber N'MOV', @Number OUTPUT, NULL;
        INSERT INTO logistics.Movements (DocumentTypeId, MovementNo, MovementTypeId, FromPlaceId, ToPlaceId, PlannedDate, StartDate, Eta,
                                         CarrierPartyId, VehicleOrVessel, VoyageNo, Reference, Notes, Status,
                                         StartedAtUtc, StartedBy, CreatedBy, SplitFromMovementId)
        SELECT m.DocumentTypeId, @Number, m.MovementTypeId, m.FromPlaceId, m.ToPlaceId, m.PlannedDate, m.StartDate, m.Eta,
               m.CarrierPartyId, m.VehicleOrVessel, m.VoyageNo, m.Reference, m.Notes, 2,
               m.StartedAtUtc, m.StartedBy, @UserId, m.Id
        FROM logistics.Movements m
        WHERE m.Id = @MovementId;
        SET @NewId = SCOPE_IDENTITY();

        -- 2. THEIR ROWS OF THE CONTAINER LIST MOVE (each row as it is), with their charges and documents filed under the
        -- movement: a file other containers share keeps their records where they are (one record per container)
        UPDATE mc SET MovementId = @NewId
        FROM logistics.MovementContainers mc
        INNER JOIN @Ids x ON x.Id = mc.ContainerId
        WHERE mc.MovementId = @MovementId;

        UPDATE ch SET MovementId = @NewId, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        FROM logistics.ContainerCharges ch
        INNER JOIN @Ids x ON x.Id = ch.ContainerId
        WHERE ch.MovementId = @MovementId;

        UPDATE a SET MovementId = @NewId
        FROM logistics.ContainerAttachments a
        INNER JOIN @Ids x ON x.Id = a.ContainerId
        WHERE a.MovementId = @MovementId;

        -- the original changed (containers left it): its RowVersion moves, a page left open on it reloads
        UPDATE logistics.Movements SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @MovementId;

        -- 3. AUDIT on both movements and on each container moved (the first 20 refs, then "and N more")
        SELECT @Refs = STRING_AGG(CAST(x.ContainerRef AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY LEN(x.ContainerRef), x.ContainerRef)
        FROM (SELECT TOP (20) ContainerRef FROM @Ids ORDER BY LEN(ContainerRef), ContainerRef) x;
        IF @Count > 20 SET @Refs = @Refs + N' and ' + CAST(@Count - 20 AS NVARCHAR(12)) + N' more';

        INSERT INTO logistics.MovementAudit (MovementId, Action, Details, UserId)
        VALUES (@MovementId, N'Split off', LEFT(N'Split off into ' + @Number + N': ' + @Refs, 1000), @UserId),
               (@NewId, N'Split from', LEFT(N'Split from ' + @MovementNo + N': ' + @Refs + N' arrived on '
                                            + CASE WHEN @Count = 1 THEN N'its own.' ELSE N'their own.' END, 1000), @UserId);

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT x.Id, N'Event', LEFT(N'Moved from ' + @MovementNo + N' to ' + @Number + N': it arrived on its own (split)', 500), @UserId
        FROM @Ids x;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @NewId = NULL;
        THROW;
    END CATCH

    SELECT NewId = m.Id, m.MovementNo, m.Status, m.RowVersion,
           OriginalMovementId = @MovementId, OriginalMovementNo = @MovementNo,
           ContainersMoved = @Count, ContainersLeft = @Left
    FROM logistics.Movements m
    WHERE m.Id = @NewId;
END
GO

/* ================================================================== 6. The next step's dialogs: can a container complete alone */

-- Re-created (82) from the body of script 81: + whether each container of a movement to complete can be split off it and
-- why not (set 1: CanSplitOff, SplitOffBlockedReason - fn_Movement_SplitBlock), and whether a Complete group of only part
-- of its movement can complete the ticked ones alone (set 2: SplitPossible, SplitBlockedReason): the dialogs offer "Only
-- KTG-2026-0031: it leaves MOV-2026-000046 and gets its own movement" / "Only the 20 ticked", disabled with the reason.
-- GET next-step reads set 1 for one container. Nothing else changes.
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
                                       COALESCE(mv.FromPlaceId, pr.FromPlaceId), N'|', COALESCE(mv.ToPlaceId, pr.ToPlaceId)) END,
           -- (82) only part of its movement arrived: can it be split off the movement in progress, and why not
           CanSplitOff = CAST(CASE WHEN s.Kind = N'Complete' AND sp.Reason IS NULL THEN 1 ELSE 0 END AS BIT),
           SplitOffBlockedReason = sp.Reason
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
    -- (82) why it cannot be split off its movement (fn_Movement_SplitBlock), for a movement to complete only
    OUTER APPLY (SELECT x.Reason
                 FROM logistics.fn_Movement_SplitBlock(mv.Id, mv.MovementNo, mv.Status, mv.Cnt, s.ContainerId, s.ContainerRef) x
                 WHERE s.Kind = N'Complete') sp
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
           ThenDefault = CAST(MIN(CAST(r.ThenDefault AS INT)) AS BIT),
           -- (82) a Complete group of only part of its movement: the ticked ones can complete alone (they get their own
           -- movement), else why not - every container of the movement is ticked, or one of them has a later leg
           SplitPossible = CAST(CASE WHEN MIN(r.Kind) = N'Complete' AND COUNT(*) < MAX(r.MovementContainerCount)
                                          AND MIN(CAST(r.CanSplitOff AS INT)) = 1 THEN 1 ELSE 0 END AS BIT),
           SplitBlockedReason = CAST(CASE WHEN MIN(r.Kind) <> N'Complete' THEN NULL
                                          WHEN COUNT(*) >= MAX(r.MovementContainerCount)
                                              THEN N'Every container of ' + MIN(r.MovementNo) + N' is ticked: complete the movement itself.'
                                          ELSE MIN(r.SplitOffBlockedReason) END AS NVARCHAR(400))
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

/* ================================================================== 7. The movement page: only some containers arrived */

-- Re-created (82) from the body of script 80: + the movement it was split off (header: SplitFromMovementId, SplitFromMovementNo),
-- whether each of its containers can be split off it and why not (set 2: CanSplitOff, SplitOffBlockedReason - the
-- checklist of "Only some containers arrived" in its Complete dialog), and its history beyond its own stamps (set 5, the
-- splits). Nothing else changes.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    -- (82) the movement's number, status and containers: whether each of them can be split off (fn_Movement_SplitBlock)
    DECLARE @MovementNo NVARCHAR(30), @MovementStatus TINYINT, @ContainerCount INT;
    SELECT @MovementNo = MovementNo, @MovementStatus = Status FROM logistics.Movements WHERE Id = @Id;
    SET @ContainerCount = (SELECT COUNT(*) FROM logistics.MovementContainers WHERE MovementId = @Id);

    SELECT m.Id, m.DocumentTypeId, m.MovementNo, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.CountryCode AS FromCountry, fp.Kind AS FromKind,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.CountryCode AS ToCountry, tp.Kind AS ToKind,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status, m.CancelReason,
           m.CarrierPartyId, cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo, m.Reference, m.Notes,
           m.StartedAtUtc, su.FullName AS StartedByName, m.CompletedAtUtc, ku.FullName AS CompletedByName,
           m.CancelledAtUtc, xu.FullName AS CancelledByName,
           m.CreatedAtUtc, m.CreatedBy, cu.FullName AS CreatedByName, m.UpdatedAtUtc, m.UpdatedBy, uu.FullName AS UpdatedByName,
           m.RowVersion,
           -- (79) the GRN type's switch: does completing a Delivery draft the goods receipts (the Complete dialog says)
           GoodsReceiptsAutomatic = CAST(ISNULL((SELECT dt.AutoCreateOnDelivery FROM inventory.DocumentTypes dt WHERE dt.Code = N'GRN'), 1) AS BIT),
           -- (80) a planned movement: why it cannot start yet (NULL = it can) and its earliest start date; a movement in
           -- progress: the earliest start date its edited start date may take (usp_Movement_Save, 70018)
           StartBlockedReason = sb.Reason, sb.StartNotBefore, sb.StartNotBeforeMovementNo, sb.StartNotBeforePlaceName,
           -- (82) the movement it was split off (usp_Movement_SplitContainers): "Split from MOV-..."
           m.SplitFromMovementId, SplitFromMovementNo = sf.MovementNo
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId
    LEFT  JOIN security.Users su ON su.Id = m.StartedBy
    LEFT  JOIN security.Users ku ON ku.Id = m.CompletedBy
    LEFT  JOIN security.Users xu ON xu.Id = m.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = m.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = m.UpdatedBy
    OUTER APPLY logistics.fn_Movement_StartBlock(m.Id) sb   -- (80)
    LEFT  JOIN logistics.Movements sf ON sf.Id = m.SplitFromMovementId                  -- (82)
    WHERE m.Id = @Id;

    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, c.Status AS ContainerStatus,
           c.CurrentLocation, c.TotalAllocatedBase, c.TotalOilQty,
           ItemSummary = CASE WHEN ln.ItemCount = 1 THEN ln.FirstItem WHEN ln.ItemCount > 1 THEN N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           SupplierName = ln.FirstSupplier,
           ChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id AND ch.MovementId = @Id AND ch.Status = 2),
           DraftChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id AND ch.MovementId = @Id AND ch.Status = 1),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ContainerId = c.Id AND a.MovementId = @Id),
           c.RowVersion AS ContainerRowVersion,
           -- (65) the container's open goods receipt (a draft or the posted one) and the warehouse its draft would take:
           -- the Complete dialog of a Delivery says what will be created ("draft goods receipt into LUB-WH", "warehouse to
           -- choose", "already has GRN-..."). WarehouseInBranch = the container's warehouse is active, of its branch and
           -- (72) at the bottom of the tree (script 70): the rule of usp_GoodsReceipt_CreateForContainer. AutoDraftOfThisMovement = the receipt is a draft made by
           -- this movement's completion: cancelling the movement deletes it (usp_Movement_SetStatus); the Cancel dialog
           -- names those edited since (GoodsReceiptUpdatedAtUtc / ByName, NULL when never edited).
           GoodsReceiptId = gr.GoodsReceiptId, GoodsReceiptNumber = gr.GoodsReceiptNumber, GoodsReceiptStatus = gr.GoodsReceiptStatus,
           WarehouseCode = w.WarehouseCode,
           WarehouseInBranch = CAST(CASE WHEN w.IsActive = 1 AND w.BranchId = c.BranchId AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1
                                         THEN 1 ELSE 0 END AS BIT),
           -- (72) why it will not be taken, NULL when it will be (or the container has none: "warehouse to choose")
           WarehouseNote = CAST(CASE WHEN w.Id IS NULL THEN NULL
                                     WHEN w.IsActive = 0 THEN w.WarehouseCode + N', the container''s, is inactive'
                                     WHEN w.BranchId <> c.BranchId THEN w.WarehouseCode + N', the container''s, is not of the container''s branch'
                                     WHEN masterdata.fn_Warehouse_IsLeaf(w.Id) = 0 THEN w.WarehouseCode + N', the container''s, has warehouses under it'
                                END AS NVARCHAR(200)),
           AutoDraftOfThisMovement = CAST(CASE WHEN g.Status = 1 AND g.IsAuto = 1 AND g.MovementId = @Id THEN 1 ELSE 0 END AS BIT),
           GoodsReceiptUpdatedAtUtc = g.UpdatedAtUtc, GoodsReceiptUpdatedByName = gu.FullName,
           -- (82) "Only some containers arrived": can it be split off this movement in progress, and why not
           CanSplitOff = CAST(CASE WHEN sp.Reason IS NULL THEN 1 ELSE 0 END AS BIT), SplitOffBlockedReason = sp.Reason
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Containers c       ON c.Id = mc.ContainerId
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) gr
    LEFT  JOIN purchase.GoodsReceipts g     ON g.Id = gr.GoodsReceiptId
    LEFT  JOIN security.Users gu            ON gu.Id = g.UpdatedBy
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), FirstItem = MIN(i.ItemName), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = c.Id) ln
    CROSS APPLY logistics.fn_Movement_SplitBlock(@Id, @MovementNo, @MovementStatus, @ContainerCount, c.Id, c.ContainerRef) sp  -- (82)
    WHERE mc.MovementId = @Id
    ORDER BY c.ContainerRef;

    SELECT ch.Id, ch.ContainerId, c.ContainerRef, ch.GroupId, ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description,
           pp.PartyName AS ProviderName, ch.Reference, ch.ChargeDate, cur.CurrencyCode, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.RowVersion
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    WHERE ch.MovementId = @Id
    ORDER BY ch.ChargeDate, c.ContainerRef, ch.Id;

    SELECT a.Id, a.ContainerId, c.ContainerRef, a.ChargeId, a.AttachmentTypeId, at.Category, at.SubType,
           a.FileId, f.FileName, f.ContentType, f.SizeBytes, a.Note, a.DocumentDate, a.GroupId,
           a.CreatedAtUtc, u.FullName AS CreatedByName
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Containers c        ON c.Id = a.ContainerId
    INNER JOIN logistics.Files f             ON f.Id = a.FileId
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    LEFT  JOIN security.Users u              ON u.Id = a.CreatedBy
    WHERE a.MovementId = @Id
    ORDER BY a.CreatedAtUtc DESC, c.ContainerRef;

    -- 5: (82) its history beyond its own stamps (logistics.MovementAudit): a split, on the original and on the copy
    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM logistics.MovementAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.MovementId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END

GO

/* ================================================================== 8. The container page's estimate follows the cost rule */

-- ONE ROW: THE FOB PER UNIT OF A CONTAINER LINE, as the container page shows it ("Real cost per item", the loaded items).
-- Once the goods are received it is the container line's own value (final: frozen by an offload of before, set by the
-- goods receipt and moved by the invoices since). Before, it is the ESTIMATE OF THE COST RULE the receipt will apply
-- (purchase.fn_GoodsReceiptLine_TargetCost, script 79): the pieces covered by invoices that change item costs at their
-- price, every other piece - not invoiced yet, or invoiced by an invoice that does not change item costs - at the order
-- price. Invoices posted or draft, as before (a draft follows its type's "Affects item cost" as it is now, as the
-- invoice's page says; a posted one what it was posted with, PurchaseDocuments.AffectsCost). The container's charges
-- are added by the caller, as before. FobSource: Received, Invoice (an invoice that changes item costs prices pieces of
-- it), Order.
CREATE OR ALTER FUNCTION logistics.fn_ContainerLine_FobEstimate (@ContainerLineId INT)
RETURNS TABLE
AS
RETURN
SELECT ContainerLineId  = cl.Id,
       OrderPriceBase   = op.Price,
       CostInvoicedBase = ISNULL(ci.Qty, 0),
       EstimatedFobBase = es.Fob,
       UnitFobBase      = COALESCE(cl.FobCostBase, es.Fob),
       FobSource        = CAST(CASE WHEN cl.FobCostBase IS NOT NULL THEN N'Received'
                                    WHEN ci.Qty > 0 THEN N'Invoice' ELSE N'Order' END AS NVARCHAR(10))
FROM logistics.ContainerLines cl
OUTER APPLY (SELECT Price = pol.LineTotal / pod.ExchangeRate / NULLIF(pol.QuantityBase, 0)
             FROM purchase.PurchaseDocumentLines pol
             INNER JOIN purchase.PurchaseDocuments pod ON pod.Id = pol.DocumentId
             WHERE pol.Id = cl.PoLineId) op
OUTER APPLY (SELECT Qty = SUM(pil.QuantityBase), Value = SUM(pil.LineTotal / d.ExchangeRate)
             FROM purchase.PurchaseDocumentLines pil
             INNER JOIN purchase.PurchaseDocuments d ON d.Id = pil.DocumentId
             INNER JOIN inventory.DocumentTypes dt   ON dt.Id = d.DocumentTypeId
             WHERE pil.ContainerLineId = cl.Id AND d.Status <> 3
               AND CASE WHEN d.Status = 1 THEN ISNULL(dt.AffectsItemCost, 1) ELSE d.AffectsCost END = 1) ci
CROSS APPLY (SELECT Fob = CAST(CASE WHEN ISNULL(ci.Qty, 0) = 0 THEN op.Price
                                    ELSE (ci.Value + CASE WHEN ci.Qty < cl.QuantityBase THEN cl.QuantityBase - ci.Qty ELSE 0 END
                                                     * COALESCE(op.Price, ci.Value / ci.Qty))
                                         / CASE WHEN ci.Qty < cl.QuantityBase THEN cl.QuantityBase ELSE ci.Qty END END
                               AS DECIMAL(18,6))) es
WHERE cl.Id = @ContainerLineId;
GO

-- Re-created (82) from the body of script 81: the FOB total (set 1) and each line's FOB per unit, source and landed cost
-- (set 2) read the estimate of the cost rule (fn_ContainerLine_FobEstimate): the pieces covered by an invoice that does
-- not change item costs (script 79) count at the order price, as at the receipt. A received line keeps its final cost.
-- Nothing else changes.
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
                 -- (82) the received value, else the estimate of the cost rule (fn_ContainerLine_FobEstimate)
                 OUTER APPLY (SELECT UnitFob = e.UnitFobBase FROM logistics.fn_ContainerLine_FobEstimate(cl.Id) e) u
                 WHERE cl.ContainerId = c.Id) cost
    WHERE c.Id = @Id;

    -- 2: lines. FOB per unit: once the goods are received the container line's value (frozen by an offload of before; set by
    -- the goods receipt and moved by the invoices since), else (82) the estimate of the cost rule: the pieces of invoices that
    -- change item costs (posted or draft) at their price, every other piece at the order price (fn_ContainerLine_FobEstimate).
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
           UnitFobBase = COALESCE(cl.FobCostBase, fe.EstimatedFobBase),                    -- (82)
           FobSource = fe.FobSource,                                                     -- (82)
           cl.FobCostBase, cl.ChargesBase,
           DraftChargesBase = ISNULL(dch.Draft, 0),
           ChargesPerUnitBase = cl.ChargesBase / NULLIF(ISNULL(cl.ReceivedQuantityBase, cl.QuantityBase), 0),
           LandedCostBase = COALESCE(cl.LandedCostBase,
                                     fe.EstimatedFobBase + cl.ChargesBase / NULLIF(cl.QuantityBase, 0)),   -- (82)
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
    CROSS APPLY logistics.fn_ContainerLine_FobEstimate(cl.Id) fe                    -- (82) the estimate of the cost rule
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

/* ================================================================== 9. Check */

-- The permission of the board and how many roles hold it.
SELECT p.Code, p.Name, p.SortOrder, Roles = (SELECT COUNT(*) FROM security.RolePermissions rp WHERE rp.PermissionId = p.Id)
FROM security.Permissions p
WHERE p.Code = N'containers.shipments.view';

-- Movements split so far: the copy, the movement it came from, how many containers each carries now.
SELECT TOP (20) Movement = m.MovementNo, SplitFrom = o.MovementNo, Status = m.Status,
       Containers = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = m.Id),
       LeftOnOriginal = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = o.Id)
FROM logistics.Movements m
INNER JOIN logistics.Movements o ON o.Id = m.SplitFromMovementId
ORDER BY m.Id DESC;

PRINT 'Script 82 applied: the Shipments board (containers by stage, one permission), a movement split when only part of it arrived, the container estimate following the cost rule.';
GO
