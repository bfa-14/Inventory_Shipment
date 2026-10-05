/* ================================================================== 1. The place rules, in one place */

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
CROSS APPLY (SELECT Reason = CAST(CASE
                 WHEN p.PreviousMovementId IS NOT NULL AND s.IsOrigin = 1
                     THEN N'Loading at the supplier is only for containers that have not moved yet.'
                 WHEN p.PreviousMovementId IS NOT NULL AND p.PlaceId <> @FromPlaceId
                     THEN N'At ' + p.PlaceName + N' (end of ' + p.PreviousMovementNo + N'), not at ' + s.FromName + N'.'
                 WHEN p.PreviousMovementId IS NULL AND p.PortOfLoadingId <> @FromPlaceId
                      AND NOT (s.IsOrigin = 1 AND p.PortOfLoadingId = ISNULL(@ToPlaceId, 0))
                     THEN N'Not moved yet: it starts from its port of loading ' + p.PortOfLoadingName + N'.' END
             AS NVARCHAR(300))) r;

GO

