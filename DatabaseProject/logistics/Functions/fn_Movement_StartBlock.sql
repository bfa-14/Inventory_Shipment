-- read for THAT container (fn_Container_PreviousMovement; the container inside the APPLY of fn_ContainerFitForMovement).
-- Taken with a movement from a row (fn_Container_ShipState, the lists, the next step), the functions over every
-- container (fn_ContainerPlaceForMovement, fn_ContainerFitForMovement) were worked out for all the containers and
-- completed movements of the database before the join kept the movement's own: 0.6 s per planned movement on 50,000
-- containers, minutes for a list holding planned legs. Nothing else changes.
CREATE   FUNCTION logistics.fn_Movement_StartBlock (@MovementId INT)
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

