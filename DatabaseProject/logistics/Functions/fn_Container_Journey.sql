/* ================================================================== 1. The journey of a container */

-- (95) ONE ROW PER CONTAINER (none for an unknown id): its latest leg that started, by movement id as everywhere (the
-- legs follow the travel order), else its status for a container followed by typed dates. Names, not ids: a list column.
CREATE   FUNCTION logistics.fn_Container_Journey (@ContainerId INT)
RETURNS TABLE
AS
RETURN
SELECT c.Id AS ContainerId,
       JourneyStatus = CAST(CASE
           WHEN c.Status = 8 THEN NULL
           WHEN c.Status IN (6, 7) THEN N'Received'
           WHEN lg.Id IS NOT NULL THEN CASE WHEN lg.Status = 2 AND lg.FromPlaceId <> lg.ToPlaceId THEN N'OnTheWay' ELSE N'Arrived' END
           WHEN c.Status = 3 THEN N'OnTheWay'
           WHEN c.Status IN (4, 5) THEN N'Arrived'
           ELSE N'NotDispatched' END AS NVARCHAR(20)),
       JourneyFromName = CASE WHEN c.Status = 8 THEN NULL WHEN lg.Id IS NOT NULL THEN fp.PortName ELSE pl.PortName END,
       JourneyToName = CASE WHEN c.Status = 8 THEN NULL
                            WHEN c.Status IN (6, 7) AND lg.Id IS NULL THEN COALESCE(w.WarehouseName, fd.PortName, pd.PortName)
                            WHEN lg.Id IS NOT NULL THEN tp.PortName
                            WHEN c.Status = 5 THEN COALESCE(fd.PortName, pd.PortName)
                            ELSE pd.PortName END,
       JourneySince = CASE WHEN c.Status = 8 THEN NULL
                           WHEN c.Status IN (6, 7) THEN c.OffloadedDate
                           WHEN lg.Id IS NOT NULL THEN CASE WHEN lg.Status = 3 THEN lg.EndDate ELSE lg.StartDate END
                           WHEN c.Status = 3 THEN c.DispatchDate
                           WHEN c.Status = 4 THEN c.ActualPortArrival
                           WHEN c.Status = 5 THEN c.CustomsReleaseDate END,
       JourneyMovementNo = CASE WHEN c.Status = 8 THEN NULL ELSE lg.MovementNo END
FROM logistics.Containers c
LEFT JOIN masterdata.Ports pl      ON pl.Id = c.PortOfLoadingId
LEFT JOIN masterdata.Ports pd      ON pd.Id = c.PortOfDestinationId
LEFT JOIN masterdata.Ports fd      ON fd.Id = c.FinalDestinationId
LEFT JOIN masterdata.Warehouses w  ON w.Id = c.WarehouseId
OUTER APPLY (SELECT TOP (1) m.Id, m.MovementNo, m.Status, m.FromPlaceId, m.ToPlaceId, m.StartDate, m.EndDate
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status IN (2, 3)
             ORDER BY m.Id DESC) lg
LEFT JOIN masterdata.Ports fp ON fp.Id = lg.FromPlaceId
LEFT JOIN masterdata.Ports tp ON tp.Id = lg.ToPlaceId
WHERE c.Id = @ContainerId;

GO

