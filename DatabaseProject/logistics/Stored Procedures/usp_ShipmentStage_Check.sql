-- not describe, with their legs ("Sea freight Chennai → Dar es Salaam (completed) | ..."), to decide on.
CREATE   PROCEDURE logistics.usp_ShipmentStage_Check
AS
BEGIN
    SET NOCOUNT ON;
    SELECT st.StageId, st.StageName, st.StageKind, st.FitsStages, Containers = COUNT(*),
           SortOrder = MIN(s.SortOrder)
    FROM logistics.Containers c
    CROSS APPLY logistics.fn_Container_Stage(c.Id) st
    LEFT JOIN logistics.ShipmentStages s ON s.Id = st.StageId
    WHERE c.Status <> 8
    GROUP BY st.StageId, st.StageName, st.StageKind, st.FitsStages
    ORDER BY CASE WHEN st.StageKind = 0 THEN 0 WHEN st.FitsStages = 0 THEN 2 ELSE 1 END, MIN(s.SortOrder), st.StageName;

    SELECT ContainerId = c.Id, c.ContainerRef, c.ContainerNo, ContainerStatus = c.Status,
           Legs = (SELECT STRING_AGG(CAST(mt.TypeName + N' ' + fp.PortName
                                          + CASE WHEN m.FromPlaceId = m.ToPlaceId THEN N'' ELSE N' → ' + tp.PortName END
                                          + CASE m.Status WHEN 2 THEN N' (in progress)' ELSE N'' END AS NVARCHAR(MAX)), N' | ')
                          WITHIN GROUP (ORDER BY m.Id)
                   FROM logistics.MovementContainers mc
                   INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                   INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
                   INNER JOIN masterdata.Ports fp ON fp.Id = m.FromPlaceId
                   INNER JOIN masterdata.Ports tp ON tp.Id = m.ToPlaceId
                   WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3))
    FROM logistics.Containers c
    CROSS APPLY logistics.fn_Container_Stage(c.Id) st
    WHERE c.Status <> 8 AND st.FitsStages = 0
    ORDER BY c.ContainerRef;
END