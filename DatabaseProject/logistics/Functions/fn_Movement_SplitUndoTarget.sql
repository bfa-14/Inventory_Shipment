-- split off). Cancelling it undoes the split (usp_Movement_SetStatus): its containers go back onto the movement they were
-- split from, whatever its status. A copy of a copy goes back to its own original, the movement it was split from - but
-- when that one was cancelled itself, ITS split was undone and its containers went back to its own original, so these
-- follow them there: up the chain while the movement reached is a cancelled split-off one ("its cancellation applies to
-- them too, like its other containers"). The first movement of a chain was never split off: the walk always ends. With
-- what the Cancel dialog says of that movement: its number, status, end date, To and stage. The one place of the rule,
-- for the Cancel itself and usp_Movement_Get. Fifty splits deep at most, as fn_Movement_Voyage.
CREATE   FUNCTION logistics.fn_Movement_SplitUndoTarget (@MovementId INT)
RETURNS TABLE
AS
RETURN
WITH up AS (SELECT p.Id, p.SplitFromMovementId, p.Status, Depth = 1
            FROM logistics.Movements m
            INNER JOIN logistics.Movements p ON p.Id = m.SplitFromMovementId
            WHERE m.Id = @MovementId
            UNION ALL
            SELECT p.Id, p.SplitFromMovementId, p.Status, up.Depth + 1
            FROM up
            INNER JOIN logistics.Movements p ON p.Id = up.SplitFromMovementId
            WHERE up.Status = 4 AND up.Depth < 50)
SELECT TOP (1) MovementId = t.Id, t.MovementNo, t.Status, t.EndDate, t.ToPlaceId, ToName = tp.PortName, mt.Stage
FROM up
INNER JOIN logistics.Movements t       ON t.Id = up.Id
INNER JOIN masterdata.MovementTypes mt ON mt.Id = t.MovementTypeId
INNER JOIN masterdata.Ports tp         ON tp.Id = t.ToPlaceId
WHERE NOT (up.Status = 4 AND up.SplitFromMovementId IS NOT NULL) OR up.Depth = 50
ORDER BY up.Depth;

GO

