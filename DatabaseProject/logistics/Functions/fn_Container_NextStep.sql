/* ================================================================== 5. The next step of one container */

-- One row per container (the container page, the dialog for one container): the step (fn_Container_NextStepKind), where
-- it is, the movement the step concerns (Complete: the one in progress; StartPlanned: the planned one) with its
-- RowVersion and dates, the proposed next leg (Ship, NextLeg) and, for a movement to complete, the leg proposed after it
-- (Then*, not after a Delivery). MovementNotBefore: the earliest date of the step (Complete: the movement's start;
-- StartPlanned: the end of the previous leg); for a new leg it is PlaceSince. ThenDefault: the "Then" box is ticked
-- by default when the next leg is a stay at the arrival place, or follows Customs or Border.
CREATE   FUNCTION logistics.fn_Container_NextStep (@ContainerId INT)
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

