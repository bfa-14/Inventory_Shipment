
/* ================================================================== 8. Containers: helpers, search, get */

-- Recomputes the totals, the derived status and the current location. Closed (7) and cancelled (8) stay.
CREATE   PROCEDURE logistics.usp_Container_RefreshStatus
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE c
    SET TotalLines         = ISNULL(x.Lines, 0),
        TotalAllocatedBase = ISNULL(x.Allocated, 0),
        TotalReceivedBase  = ISNULL(x.Received, 0),
        TotalOilQty        = ISNULL(x.Oil, 0),
        Status = CASE WHEN c.Status IN (7, 8) THEN c.Status
                      WHEN c.OffloadedDate IS NOT NULL THEN 6
                      WHEN c.CustomsReleaseDate IS NOT NULL THEN 5
                      WHEN c.ActualPortArrival IS NOT NULL THEN 4
                      WHEN c.DispatchDate IS NOT NULL THEN 3
                      WHEN c.ConfirmedAtUtc IS NOT NULL THEN 2
                      ELSE 1 END,
        CurrentLocation = COALESCE(ev.Place,
                                   CASE WHEN c.OffloadedDate IS NOT NULL THEN (SELECT WarehouseName FROM masterdata.Warehouses WHERE Id = c.WarehouseId)
                                        WHEN c.CustomsReleaseDate IS NOT NULL OR c.ActualPortArrival IS NOT NULL
                                             THEN (SELECT PortName FROM masterdata.Ports WHERE Id = c.PortOfDestinationId)
                                        WHEN c.DispatchDate IS NOT NULL THEN N'In transit'
                                        ELSE NULL END)
    FROM logistics.Containers c
    CROSS APPLY (SELECT Lines = COUNT(*), Allocated = SUM(QuantityBase), Received = SUM(ISNULL(ReceivedQuantityBase, 0)),
                        Oil = SUM(TotalOilQty)
                 FROM logistics.ContainerLines WHERE ContainerId = @Id) x
    OUTER APPLY (SELECT TOP (1) Place = COALESCE(p.PortName, e.LocationText)
                 FROM logistics.ContainerEvents e
                 LEFT JOIN masterdata.Ports p ON p.Id = e.PortId
                 WHERE e.ContainerId = @Id AND (p.PortName IS NOT NULL OR e.LocationText IS NOT NULL)
                 ORDER BY e.EventDate DESC, e.Id DESC) ev
    WHERE c.Id = @Id;
END
GO

