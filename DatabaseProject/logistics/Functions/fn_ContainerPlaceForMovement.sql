-- NOT cancelled with the highest Id below @MovementId (with NULL: the highest Id), and that movement's To.
-- No previous movement = never moved: PlaceId NULL, any From is accepted.
CREATE   FUNCTION logistics.fn_ContainerPlaceForMovement (@MovementId INT)
RETURNS TABLE
AS
RETURN
SELECT c.Id AS ContainerId,
       PreviousMovementId = pm.Id, PreviousMovementNo = pm.MovementNo, PreviousStatus = pm.Status,
       PlaceId = pm.ToPlaceId, PlaceName = tp.PortName,
       c.PortOfLoadingId, PortOfLoadingName = pl.PortName
FROM logistics.Containers c
LEFT JOIN masterdata.Ports pl ON pl.Id = c.PortOfLoadingId
OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, m.Status, m.ToPlaceId
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status <> 4 AND (@MovementId IS NULL OR m.Id < @MovementId)
             ORDER BY m.Id DESC) pm
LEFT JOIN masterdata.Ports tp ON tp.Id = pm.ToPlaceId;

GO

