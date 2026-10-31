/* ================================================================== 1b. A planned movement's refusal, fast on any number of containers */

-- THE PREVIOUS MOVEMENT OF ONE CONTAINER before @MovementId (NULL = its latest): its movement not cancelled with the
-- highest Id below - the "previous" of fn_ContainerPlaceForMovement, read for one container only (the index on
-- (ContainerId, MovementId)). At most one row.
CREATE   FUNCTION logistics.fn_Container_PreviousMovement (@ContainerId INT, @MovementId INT)
RETURNS TABLE
AS
RETURN
SELECT TOP (1) m.Id, m.MovementNo, m.Status, m.MovementTypeId, m.FromPlaceId, m.ToPlaceId, m.StartDate, m.EndDate
FROM logistics.MovementContainers mc
INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
WHERE mc.ContainerId = @ContainerId AND m.Status <> 4 AND (@MovementId IS NULL OR mc.MovementId < @MovementId)
ORDER BY mc.MovementId DESC;

GO

