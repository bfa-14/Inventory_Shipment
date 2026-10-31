/* ================================================================== 8. "Add to a movement...": the movements a container can join */

-- The PLANNED movements @ContainerId can really join: not on it yet, created after its latest movement (legs follow the
-- travel order: "previous" is the movement with the highest Id below, so joining an older one would put it before a
-- leg already made), and passing the checks usp_Movement_Save makes for it at that movement's From, To and type
-- (fn_Movement_ContainerCheck: not received, closed or cancelled; at the From). Newest first, every one of them.
-- 70006 when there is no such container.
CREATE   PROCEDURE logistics.usp_Movement_JoinCandidates
    @ContainerId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @ContainerId) THROW 70006, 'Container not found.', 1;

    DECLARE @Latest INT = (SELECT MAX(m.Id)
                           FROM logistics.MovementContainers mc
                           INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
                           WHERE mc.ContainerId = @ContainerId AND m.Status <> 4);

    SELECT m.Id, m.MovementNo, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName,
           m.PlannedDate, m.Eta, m.Status,
           m.CarrierPartyId, cp.PartyName AS CarrierName, m.VehicleOrVessel,
           ContainerCount = ISNULL(ctn.Cnt, 0),
           ContainerRefs = CASE WHEN ISNULL(ctn.Cnt, 0) = 0 THEN NULL WHEN ctn.Cnt = 1 THEN ctn.FirstRef
                                ELSE ctn.FirstRef + N' +' + CAST(ctn.Cnt - 1 AS NVARCHAR(10)) END,
           k.Note,
           m.RowVersion
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId
    CROSS APPLY (SELECT x.CanAdd, x.OnMovement, x.Note
                 FROM logistics.fn_Movement_ContainerCheck(m.Id, m.FromPlaceId, m.ToPlaceId, m.MovementTypeId) x
                 WHERE x.ContainerId = @ContainerId) k
    OUTER APPLY (SELECT Cnt = COUNT(*), FirstRef = MIN(c.ContainerRef)
                 FROM logistics.MovementContainers mc INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
                 WHERE mc.MovementId = m.Id) ctn
    WHERE m.Status = 1
      AND m.Id > ISNULL(@Latest, 0)
      AND k.OnMovement = 0 AND k.CanAdd = 1
    ORDER BY m.Id DESC;
END

GO

