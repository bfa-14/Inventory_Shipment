/* ================================================================== 8. Container status from the movements */

-- Status (milestones, never back): 1 Draft, 2 Confirmed, 3 In Transit, 4 At Port, 5 Cleared, 6 Offloaded, 7 Closed, 8 Cancelled.
-- With movements (started or completed) the milestone dates come from them - for good once a container has travelled
-- with one (DatesFromMovements); a container that never moved keeps the dates typed on its header.
CREATE   PROCEDURE logistics.usp_Container_RefreshStatus
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasMovements BIT = 0, @Level INT = 2, @Dispatch DATE, @PortArrival DATE, @Border DATE, @Customs DATE;

    SELECT @HasMovements = CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END,
           @Level = ISNULL(MAX(CASE WHEN mt.Stage = N'Delivery' THEN 5
                                    WHEN mt.Stage = N'Customs' AND m.Status = 3 THEN 5
                                    WHEN mt.Stage = N'Port' THEN 4
                                    WHEN mt.Stage = N'Sea' AND m.Status = 3 THEN 4
                                    WHEN mt.Stage = N'Origin' THEN 2
                                    ELSE 3 END), 2),
           @Dispatch    = MIN(CASE WHEN mt.Stage IN (N'Sea', N'Transit', N'Border') THEN m.StartDate END),
           @PortArrival = MAX(CASE WHEN mt.Stage = N'Sea' AND m.Status = 3 THEN m.EndDate WHEN mt.Stage = N'Port' THEN m.StartDate END),
           @Border      = MAX(CASE WHEN mt.Stage = N'Border' THEN m.StartDate END),
           @Customs     = MAX(CASE WHEN mt.Stage = N'Customs' AND m.Status = 3 THEN m.EndDate END)
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Movements m       ON m.Id = mc.MovementId
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    WHERE mc.ContainerId = @Id AND m.Status IN (2, 3);

    -- once the container has travelled with a movement, the dates always follow the movements (NULL when none is left)
    IF @HasMovements = 1 OR EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND DatesFromMovements = 1)
        UPDATE logistics.Containers
        SET DispatchDate = @Dispatch, ActualPortArrival = @PortArrival, BorderCrossingDate = @Border, CustomsReleaseDate = @Customs,
            DatesFromMovements = 1
        WHERE Id = @Id;

    UPDATE c
    SET TotalLines         = ISNULL(x.Lines, 0),
        TotalAllocatedBase = ISNULL(x.Allocated, 0),
        TotalReceivedBase  = ISNULL(x.Received, 0),
        TotalOilQty        = ISNULL(x.Oil, 0),
        Status = CASE WHEN c.Status IN (7, 8) THEN c.Status
                      WHEN c.OffloadedDate IS NOT NULL THEN 6
                      WHEN c.ConfirmedAtUtc IS NULL THEN 1
                      ELSE (SELECT MAX(s.v) FROM (VALUES (2),
                                                         (CASE WHEN @HasMovements = 1 THEN @Level END),
                                                         (CASE WHEN c.CustomsReleaseDate IS NOT NULL THEN 5
                                                               WHEN c.ActualPortArrival IS NOT NULL THEN 4
                                                               WHEN c.DispatchDate IS NOT NULL THEN 3 END)) s (v)) END,
        CurrentLocation = CASE WHEN c.Status = 8 THEN c.CurrentLocation
                               WHEN c.OffloadedDate IS NOT NULL THEN LEFT(w.WarehouseName, 100)
                               WHEN mv.Place IS NOT NULL THEN LEFT(mv.Place, 100)
                               WHEN c.CustomsReleaseDate IS NOT NULL OR c.ActualPortArrival IS NOT NULL THEN pd.PortName
                               WHEN c.DispatchDate IS NOT NULL THEN N'In transit'
                               END
    FROM logistics.Containers c
    LEFT JOIN masterdata.Warehouses w ON w.Id = c.WarehouseId
    LEFT JOIN masterdata.Ports pd     ON pd.Id = c.PortOfDestinationId
    CROSS APPLY (SELECT Lines = COUNT(*), Allocated = SUM(QuantityBase), Received = SUM(ISNULL(ReceivedQuantityBase, 0)),
                        Oil = SUM(TotalOilQty)
                 FROM logistics.ContainerLines WHERE ContainerId = @Id) x
    OUTER APPLY (SELECT TOP (1) Place = CASE WHEN m.Status = 3 THEN tp.PortName
                                             WHEN m.FromPlaceId = m.ToPlaceId THEN mt.TypeName + N' - ' + fp.PortName
                                             ELSE mt.TypeName + N': ' + fp.PortName + N' ' + NCHAR(8594) + N' ' + tp.PortName END
                 FROM logistics.MovementContainers mc
                 INNER JOIN logistics.Movements m       ON m.Id = mc.MovementId
                 INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
                 INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
                 INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
                 WHERE mc.ContainerId = @Id AND m.Status IN (2, 3)
                 ORDER BY CASE WHEN m.Status = 2 THEN 0 ELSE 1 END, COALESCE(m.EndDate, m.StartDate) DESC, m.Id DESC) mv
    WHERE c.Id = @Id;
END

GO

