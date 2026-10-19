/* ================================================================== 4. The Shipments board */

-- Logistics › Shipments: one row per container on the board, with its card, its column (fn_Container_BoardPhase) and its
-- group in the column; then the containers and pieces of each column (the columns of the board, left to right, Received
-- only with @ShowReceived). The filters are the server's; NO PAGING (the board shows every container on its way).
-- Groups in a column (GroupKey, GroupLabel; GroupOrder = their order in the column):
--   At supplier      by port of loading ("Chennai"; "No port of loading")
--   At sea           by movement ("MOV-2026-000046 · MSC Aurora V.123 · Chennai → Dar es Salaam · ETA 20/10/2026"); the
--                    containers followed by typed dates in one group of their own, last ("Followed by typed dates")
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
CREATE   PROCEDURE logistics.usp_Shipment_Board
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
           -- (a container followed by typed dates - In Transit to Cleared without a leg - has neither leg: at port, its
           -- port of destination; cleared or received by hand, that port, else its final destination - where
           -- usp_Container_RefreshStatus puts it)
           AtPlaceId = CASE ph.Phase WHEN N'AtSupplier' THEN b.PortOfLoadingId
                                     WHEN N'AtPort' THEN COALESCE(b.ActiveMovementToPlaceId, b.LastToPlaceId, b.PortOfDestinationId)
                                     WHEN N'AtBorderCustoms' THEN COALESCE(b.ActiveMovementToPlaceId, b.LastToPlaceId,
                                                                           b.PortOfDestinationId, b.FinalDestinationId)
                                     WHEN N'Delivered' THEN COALESCE(b.DeliveryPlaceId, b.LastToPlaceId,
                                                                     CASE WHEN b.Status BETWEEN 3 AND 5
                                                                          THEN COALESCE(b.PortOfDestinationId, b.FinalDestinationId) END,
                                                                     b.PortOfLoadingId) END,
           AtPlaceName = CASE ph.Phase WHEN N'AtSupplier' THEN b.PortOfLoadingName
                                       WHEN N'AtPort' THEN COALESCE(b.ActiveMovementToName, b.LastToName, b.PortOfDestinationName)
                                       WHEN N'AtBorderCustoms' THEN COALESCE(b.ActiveMovementToName, b.LastToName,
                                                                             b.PortOfDestinationName, b.FinalDestinationName)
                                       WHEN N'Delivered' THEN COALESCE(b.DeliveryPlaceName, b.LastToName,
                                                                       CASE WHEN b.Status BETWEEN 3 AND 5
                                                                            THEN COALESCE(b.PortOfDestinationName, b.FinalDestinationName) END,
                                                                       b.PortOfLoadingName) END,
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
           -- followed by typed dates: no leg started or completed, above Confirmed by the dates typed on it (NULL otherwise,
           -- so the board's answer leaves it out)
           FollowedByTypedDates = CAST(CASE WHEN b.ActiveMovementId IS NULL AND b.LastMovementId IS NULL AND b.Status BETWEEN 3 AND 5
                                            THEN 1 END AS BIT),
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
                            -- a container followed by typed dates is at sea on no movement: a group of its own
                            WHEN N'AtSea' THEN ISNULL(N'MOV|' + CAST(b.ActiveMovementId AS NVARCHAR(12)), N'TYPED')
                            WHEN N'OnTheRoad' THEN N'LEG|' + CAST(b.ActiveMovementFromPlaceId AS NVARCHAR(12)) + N'|'
                                                   + CAST(b.ActiveMovementToPlaceId AS NVARCHAR(12))
                            WHEN N'Received' THEN N'WH|' + ISNULL(CAST(rw.ReceivedWarehouseId AS NVARCHAR(12)), N'0')
                            ELSE N'AT|' + ISNULL(CAST(s.AtPlaceId AS NVARCHAR(12)), N'0') END,
                        GroupLabel = CAST(CASE s.Phase
                            WHEN N'AtSea' THEN CASE WHEN b.ActiveMovementId IS NULL THEN N'Followed by typed dates' ELSE
                                     CONCAT_WS(N' ' + NCHAR(183) + N' ', b.ActiveMovementNo,
                                     NULLIF(CONCAT_WS(N' ', b.ActiveMovementVehicleOrVessel,
                                                      CASE WHEN b.ActiveMovementVoyageNo IS NULL THEN NULL
                                                           WHEN b.ActiveMovementVoyageNo LIKE N'V%' THEN b.ActiveMovementVoyageNo
                                                           ELSE N'V.' + b.ActiveMovementVoyageNo END), N''),
                                     b.ActiveMovementFromName + N' ' + NCHAR(8594) + N' ' + b.ActiveMovementToName,
                                     N'ETA ' + CONVERT(NVARCHAR(10), b.ActiveMovementEta, 103)) END
                            -- a stay on the road (a border crossing) has no From -> To: "Border crossing at Kasumbalesa"
                            WHEN N'OnTheRoad' THEN CASE WHEN b.ActiveMovementFromPlaceId = b.ActiveMovementToPlaceId
                                                        THEN b.ActiveMovementTypeName + N' at ' + b.ActiveMovementFromName
                                                        ELSE b.ActiveMovementFromName + N' ' + NCHAR(8594) + N' ' + b.ActiveMovementToName END
                            WHEN N'AtSupplier' THEN ISNULL(s.AtPlaceName, N'No port of loading')
                            WHEN N'Received' THEN ISNULL(rw.ReceivedWarehouseName, N'No warehouse')
                            ELSE ISNULL(s.AtPlaceName, N'Place unknown') END AS NVARCHAR(300)),
                        SortNone = CASE WHEN s.Phase = N'Received' AND rw.ReceivedWarehouseId IS NULL THEN 1
                                        WHEN s.Phase NOT IN (N'AtSea', N'OnTheRoad', N'Received') AND s.AtPlaceId IS NULL THEN 1
                                        WHEN s.Phase = N'AtSea' AND b.ActiveMovementId IS NULL THEN 1   -- typed dates, after the ships
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

