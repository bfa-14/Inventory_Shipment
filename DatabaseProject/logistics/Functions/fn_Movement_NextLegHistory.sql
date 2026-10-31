-- the containers that did got a movement of their own with the same type, From, To and start: one voyage, not two
-- "earlier legs" (fn_Movement_Voyage), so one split voyage alone never reaches "seen at least twice". Nothing else
-- changes.
-- At most one row: the next leg most often taken from @PlaceId by the containers whose previous leg (the movement not
-- cancelled with the highest Id below, as everywhere) had the stage @LastStage and ended there - with @LastStage NULL,
-- the first leg of containers that never moved before. Movements of the last 365 days (start, else planned, else created),
-- planned, in progress or completed, counted once each however many containers they carry - (82) a voyage split in two
-- once; seen at least twice; ties go to the most recent. A Loading at the supplier is never proposed (it is only for
-- containers that never moved and leaves from the supplier, not from here), nor an inactive type or place.
-- WORKED OUT ONCE PER (place, last stage): usp_Container_NextStepPreview and the list call it per group, not per row.
CREATE   FUNCTION logistics.fn_Movement_NextLegHistory (@PlaceId INT, @LastStage NVARCHAR(10))
RETURNS TABLE
AS
RETURN
SELECT TOP (1) m.MovementTypeId, m.ToPlaceId, Legs = COUNT(DISTINCT vg.VoyageId)
FROM logistics.Movements m
INNER JOIN masterdata.MovementTypes t ON t.Id = m.MovementTypeId AND t.IsActive = 1 AND t.Stage <> N'Origin'
INNER JOIN masterdata.Ports tp        ON tp.Id = m.ToPlaceId AND tp.IsActive = 1
-- (82) its voyage: itself, the movement it was split off, or for a split of a split the first one of its chain (the
-- recursion read only then: read for every split movement, it made a place of 1,000 split voyages half as slow again)
LEFT JOIN logistics.Movements sp     ON sp.Id = m.SplitFromMovementId
CROSS APPLY (SELECT VoyageId = CASE WHEN m.SplitFromMovementId IS NULL THEN m.Id
                                    WHEN sp.SplitFromMovementId IS NULL THEN sp.Id
                                    ELSE (SELECT v.VoyageId FROM logistics.fn_Movement_Voyage(m.Id) v) END) vg
WHERE m.FromPlaceId = @PlaceId
  AND m.Status IN (1, 2, 3)
  AND COALESCE(m.StartDate, m.PlannedDate, CAST(m.CreatedAtUtc AS DATE)) >= DATEADD(DAY, -365, CAST(SYSUTCDATETIME() AS DATE))
  AND EXISTS (SELECT 1
              FROM logistics.MovementContainers mc
              OUTER APPLY (SELECT TOP (1) pm.ToPlaceId, pt.Stage
                           FROM logistics.MovementContainers pc
                           INNER JOIN logistics.Movements pm      ON pm.Id = pc.MovementId
                           INNER JOIN masterdata.MovementTypes pt ON pt.Id = pm.MovementTypeId
                           WHERE pc.ContainerId = mc.ContainerId AND pm.Status <> 4 AND pm.Id < m.Id
                           ORDER BY pm.Id DESC) pv
              WHERE mc.MovementId = m.Id
                AND ((@LastStage IS NULL AND pv.Stage IS NULL)
                     OR (pv.Stage = @LastStage AND pv.ToPlaceId = @PlaceId)))
GROUP BY m.MovementTypeId, m.ToPlaceId
HAVING COUNT(DISTINCT vg.VoyageId) >= 2
ORDER BY COUNT(DISTINCT vg.VoyageId) DESC, MAX(m.Id) DESC;

GO

