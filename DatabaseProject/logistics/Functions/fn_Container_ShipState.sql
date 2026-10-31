/* ================================================================== 2. Where a container is, and its movements */

-- One row per container. "Previous" keeps the meaning of fn_ContainerPlaceForMovement: the movement NOT cancelled with
-- the highest Id. Place = the To of that movement (planned, in progress or completed), else the port of loading of a
-- container that never moved (NULL when it has none: any From fits it). PlaceSince = its end date once completed.
-- Active = the movement in progress that carries it (one at most: 70012). Planned = its next planned movement (the
-- lowest Id ABOVE the latest movement it started or made: an older planned one would send it back to a place it has
-- left, and fn_ContainerFitForMovement refuses it), with why it cannot start yet and its earliest start
-- (fn_Movement_StartBlock). Last = its last completed movement. The API makes the next step of it
-- (ContainerStatusFlags.ShipStep).
CREATE   FUNCTION logistics.fn_Container_ShipState (@ContainerId INT)
RETURNS TABLE
AS
RETURN
SELECT c.Id AS ContainerId,
       MovementCount = ISNULL(n.Cnt, 0),
       PlaceId   = CASE WHEN lm.Id IS NULL THEN c.PortOfLoadingId ELSE lm.ToPlaceId END,
       PlaceName = CASE WHEN lm.Id IS NULL THEN pl.PortName ELSE lp.PortName END,
       PlaceSince = CASE WHEN lm.Status = 3 THEN lm.EndDate END,
       ActiveMovementId = ip.Id, ActiveMovementNo = ip.MovementNo, ActiveMovementTypeName = ip.TypeName,
       ActiveMovementStage = ip.Stage, ActiveMovementFromName = ip.FromName, ActiveMovementToName = ip.ToName,
       ActiveMovementStartDate = ip.StartDate, ActiveMovementEta = ip.Eta, ActiveMovementContainerCount = ip.Cnt,
       PlannedMovementId = np.Id, PlannedMovementNo = np.MovementNo, PlannedMovementTypeName = np.TypeName,
       PlannedMovementStage = np.Stage, PlannedMovementFromName = np.FromName, PlannedMovementToName = np.ToName,
       PlannedMovementDate = np.PlannedDate, PlannedMovementContainerCount = np.Cnt,
       PlannedMovementBlockedReason = sb.Reason, PlannedMovementNotBefore = sb.StartNotBefore,
       LastMovementId = lc.Id, LastMovementNo = lc.MovementNo, LastMovementEndDate = lc.EndDate
FROM logistics.Containers c
LEFT JOIN masterdata.Ports pl ON pl.Id = c.PortOfLoadingId
OUTER APPLY (SELECT Cnt = COUNT(*)
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status <> 4) n
OUTER APPLY (SELECT TOP (1) m.Id, m.Status, m.ToPlaceId, m.EndDate
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status <> 4
             ORDER BY m.Id DESC) lm
LEFT JOIN masterdata.Ports lp ON lp.Id = lm.ToPlaceId
OUTER APPLY (SELECT MaxId = MAX(m.Id)
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)) ls
OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, mt.TypeName, mt.Stage, FromName = fp.PortName, ToName = tp.PortName,
                    m.StartDate, m.Eta,
                    Cnt = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = m.Id)
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m       ON m.Id = mc.MovementId
             INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
             INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
             INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
             WHERE mc.ContainerId = c.Id AND m.Status = 2
             ORDER BY m.Id DESC) ip
OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, mt.TypeName, mt.Stage, FromName = fp.PortName, ToName = tp.PortName,
                    m.PlannedDate,
                    Cnt = (SELECT COUNT(*) FROM logistics.MovementContainers x WHERE x.MovementId = m.Id)
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m       ON m.Id = mc.MovementId
             INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
             INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
             INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
             WHERE mc.ContainerId = c.Id AND m.Status = 1 AND m.Id > ISNULL(ls.MaxId, 0)
             ORDER BY m.Id ASC) np
OUTER APPLY logistics.fn_Movement_StartBlock(np.Id) sb
OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, m.EndDate
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status = 3
             ORDER BY m.Id DESC) lc
WHERE c.Id = @ContainerId;

GO

