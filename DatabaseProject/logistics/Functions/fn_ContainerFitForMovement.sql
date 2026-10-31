/* ================================================================== 1b. The place rules: never behind a leg already made */

-- Re-created (80) from the body of script 53: + a container that already travelled with a LATER movement (in progress
-- or completed) does not fit an older planned or in-progress one. "Previous" is the movement with the highest Id BELOW
-- @MovementId, so on an older movement the container was judged by a leg it had long finished: it could be added to it
-- and started from a place it had already left, two journeys at once. Save (70015), Start (70015), the movement page's
-- picker and Start's reason on the lists (fn_Movement_StartBlock) all read this one function. A LATER movement only
-- planned still fits (planning ahead), and a completed or cancelled @MovementId is never judged (its history stays).
-- One row per container for a movement (@MovementId NULL = a new one) leaving @FromPlaceId for @ToPlaceId with the
-- type @MovementTypeId: where the container is (its previous movement's To, else its port of loading), whether it
-- fits the movement and why not. Note only on a container that never moved and fits.
CREATE   FUNCTION logistics.fn_ContainerFitForMovement (@MovementId INT, @FromPlaceId INT, @ToPlaceId INT, @MovementTypeId INT)
RETURNS TABLE
AS
RETURN
SELECT p.ContainerId, p.PreviousMovementId, p.PreviousMovementNo, p.PreviousStatus,
       PlaceId   = CASE WHEN p.PreviousMovementId IS NULL THEN p.PortOfLoadingId ELSE p.PlaceId END,
       PlaceName = CASE WHEN p.PreviousMovementId IS NULL THEN p.PortOfLoadingName ELSE p.PlaceName END,
       p.PortOfLoadingId, p.PortOfLoadingName, s.IsOrigin,
       Fits = CAST(CASE WHEN r.Reason IS NULL THEN 1 ELSE 0 END AS BIT),
       r.Reason,
       Note = CAST(CASE WHEN r.Reason IS NULL AND p.PreviousMovementId IS NULL
                        THEN ISNULL(N'Not moved yet - port of loading: ' + p.PortOfLoadingName + N'.',
                                    N'No port of loading on this container: check it.') END AS NVARCHAR(200))
FROM logistics.fn_ContainerPlaceForMovement(@MovementId) p
CROSS JOIN (SELECT IsOrigin = CAST(CASE WHEN EXISTS (SELECT 1 FROM masterdata.MovementTypes t
                                                     WHERE t.Id = @MovementTypeId AND t.Stage = N'Origin') THEN 1 ELSE 0 END AS BIT),
                   FromName = (SELECT f.PortName FROM masterdata.Ports f WHERE f.Id = @FromPlaceId)) s
-- (80) the latest movement it started or made after this one (only while this one is planned or in progress)
OUTER APPLY (SELECT TOP (1) lm.MovementNo, LegFrom = lf.PortName, LegTo = lt.PortName
             FROM logistics.MovementContainers lc
             INNER JOIN logistics.Movements lm ON lm.Id = lc.MovementId
             INNER JOIN masterdata.Ports lf    ON lf.Id = lm.FromPlaceId
             INNER JOIN masterdata.Ports lt    ON lt.Id = lm.ToPlaceId
             WHERE lc.ContainerId = p.ContainerId AND lm.Id > @MovementId AND lm.Status IN (2, 3)
               AND EXISTS (SELECT 1 FROM logistics.Movements om WHERE om.Id = @MovementId AND om.Status IN (1, 2))
             ORDER BY lm.Id DESC) ll
CROSS APPLY (SELECT Reason = CAST(CASE
                 WHEN ll.MovementNo IS NOT NULL                                                      -- (80)
                     THEN N'Already travelled further with ' + ll.MovementNo + N' (' + ll.LegFrom + N' ' + NCHAR(8594) + N' '
                          + ll.LegTo + N'), a later movement: take it off this one.'
                 WHEN p.PreviousMovementId IS NOT NULL AND s.IsOrigin = 1
                     THEN N'Loading at the supplier is only for containers that have not moved yet.'
                 WHEN p.PreviousMovementId IS NOT NULL AND p.PlaceId <> @FromPlaceId
                     THEN N'At ' + p.PlaceName + N' (end of ' + p.PreviousMovementNo + N'), not at ' + s.FromName + N'.'
                 WHEN p.PreviousMovementId IS NULL AND p.PortOfLoadingId <> @FromPlaceId
                      AND NOT (s.IsOrigin = 1 AND p.PortOfLoadingId = ISNULL(@ToPlaceId, 0))
                     THEN N'Not moved yet: it starts from its port of loading ' + p.PortOfLoadingName + N'.' END
             AS NVARCHAR(300))) r;

GO

