/* ================================================================== 3. Where a container stands */

-- (111) ONE ROW PER CONTAINER. Its legs are its movements started or completed (planned and cancelled ones do not
-- count). The stage, the first that applies:
--   received (6, 7)                 the Offload stage of the place its last leg reached, else any Offload stage
--   a leg in progress               the Leg stage of the same type and To, from the same From - or from the port of
--                                   loading (FromPlaceId NULL) when it is its first leg
--   its last leg completed          the Arrive stage of that place, else its Offload stage (delivered, waiting for its
--                                   goods receipt: ReceiptPending)
--   no leg                          Pending (StageKind 0) - "Followed by typed dates" when its status moved without one
--   else                            "Not on a stage" (FitsStages 0)
-- Inactive stages still name where a container stands.
CREATE   FUNCTION logistics.fn_Container_Stage (@ContainerId INT)
RETURNS TABLE
AS
RETURN
SELECT c.Id AS ContainerId,
       StageId = s.Id,
       StageName = CAST(CASE WHEN c.Status = 8 THEN NULL
                             WHEN s.Id IS NOT NULL THEN s.StageName
                             WHEN c.Status IN (6, 7) THEN N'Offloaded'
                             WHEN ISNULL(n.Cnt, 0) = 0 AND c.Status IN (1, 2) THEN N'Pending'
                             WHEN ISNULL(n.Cnt, 0) = 0 THEN N'Followed by typed dates'
                             ELSE N'Not on a stage' END AS NVARCHAR(100)),
       StageKind = CAST(CASE WHEN c.Status = 8 THEN NULL
                             WHEN s.Id IS NOT NULL THEN s.Kind
                             WHEN c.Status IN (6, 7) THEN 3
                             WHEN ISNULL(n.Cnt, 0) = 0 THEN 0 END AS TINYINT),
       FitsStages = CAST(CASE WHEN c.Status = 8 OR s.Id IS NOT NULL OR c.Status IN (6, 7) OR ISNULL(n.Cnt, 0) = 0
                              THEN 1 ELSE 0 END AS BIT),
       ReceiptPending = CAST(CASE WHEN s.Kind = 3 AND c.Status < 6 THEN 1 ELSE 0 END AS BIT),
       MovementCount = ISNULL(n.Cnt, 0),
       ActiveMovementId = act.Id, ActiveMovementNo = act.MovementNo, ActiveToPlaceId = act.ToPlaceId,
       -- where it stands: its last leg's To once arrived, its port of loading before its first leg, none while travelling
       PlaceId = CASE WHEN act.Id IS NOT NULL THEN NULL WHEN lst.Id IS NULL THEN c.PortOfLoadingId ELSE lst.ToPlaceId END,
       LastLegToPlaceId = lst.ToPlaceId,
       StageSince = CASE WHEN c.Status IN (6, 7) THEN c.OffloadedDate WHEN act.Id IS NOT NULL THEN act.StartDate ELSE lst.EndDate END
FROM logistics.Containers c
OUTER APPLY (SELECT Cnt = COUNT(*)
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)) n
OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, m.MovementTypeId, m.FromPlaceId, m.ToPlaceId, m.StartDate
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status = 2
             ORDER BY m.Id DESC) act
OUTER APPLY (SELECT TOP (1) m.Id, m.ToPlaceId, m.EndDate
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)
             ORDER BY m.Id DESC) lst
OUTER APPLY (SELECT TOP (1) st.Id, st.StageName, st.Kind
             FROM logistics.ShipmentStages st
             WHERE c.Status <> 8
               AND ((c.Status IN (6, 7) AND st.Kind = 3)
                    OR (c.Status < 6 AND act.Id IS NOT NULL AND st.Kind = 1 AND st.MovementTypeId = act.MovementTypeId
                        AND st.ToPlaceId = act.ToPlaceId
                        AND (st.FromPlaceId = act.FromPlaceId OR (st.FromPlaceId IS NULL AND n.Cnt = 1)))
                    OR (c.Status < 6 AND act.Id IS NULL AND lst.Id IS NOT NULL AND st.Kind IN (2, 3) AND st.ToPlaceId = lst.ToPlaceId))
             ORDER BY CASE WHEN st.ToPlaceId = lst.ToPlaceId THEN 0 ELSE 1 END,
                      CASE WHEN st.Kind = 2 THEN 0 ELSE 1 END,
                      CASE WHEN st.FromPlaceId IS NOT NULL THEN 0 ELSE 1 END,
                      st.IsActive DESC, st.SortOrder, st.Id) s
WHERE c.Id = @ContainerId;