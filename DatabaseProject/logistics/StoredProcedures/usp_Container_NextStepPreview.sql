/* ================================================================== 6. The next step's dialogs: can a container complete alone */

-- Re-created (82) from the body of script 81: + whether each container of a movement to complete can be split off it and
-- why not (set 1: CanSplitOff, SplitOffBlockedReason - fn_Movement_SplitBlock), and whether a Complete group of only part
-- of its movement can complete the ticked ones alone (set 2: SplitPossible, SplitBlockedReason): the dialogs offer "Only
-- KTG-2026-0031: it leaves MOV-2026-000046 and gets its own movement" / "Only the 20 ticked", disabled with the reason.
-- GET next-step reads set 1 for one container. Nothing else changes.
CREATE   PROCEDURE logistics.usp_Container_NextStepPreview
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

