CREATE   PROCEDURE logistics.usp_Container_Tracking
    @ContainerId   INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @OffloadedDays INT           = 30
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @Ids TABLE (Id INT PRIMARY KEY);
    INSERT INTO @Ids (Id)
    SELECT c.Id FROM logistics.Containers c
    WHERE (@ContainerId IS NULL OR c.Id = @ContainerId)
      AND (@ContainerId IS NOT NULL OR c.Status IN (2, 3, 4, 5)
           OR (c.Status IN (6, 7) AND c.OffloadedDate >= DATEADD(DAY, -ISNULL(@OffloadedDays, 30), @Today)))
      AND (@Search IS NULL OR c.ContainerRef LIKE N'%' + @Search + N'%' OR c.ContainerNo LIKE N'%' + @Search + N'%'
           OR c.BlNo LIKE N'%' + @Search + N'%' OR c.VesselName LIKE N'%' + @Search + N'%');

    -- 1: containers
    SELECT c.Id, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, c.Status, c.CurrentLocation,
           c.DispatchDate, c.Eta, c.ActualPortArrival, c.CustomsReleaseDate, c.OffloadedDate, c.LastFreeDay,
           DaysAtPort = CASE WHEN c.ActualPortArrival IS NOT NULL
                             THEN DATEDIFF(DAY, c.ActualPortArrival, ISNULL(c.OffloadedDate, @Today)) END,
           c.TotalAllocatedBase, c.TotalOilQty,
           ItemSummary = CASE WHEN ln.ItemCount = 1 THEN ln.FirstItem WHEN ln.ItemCount > 1 THEN N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           SupplierName = ln.FirstSupplier,
           pl.PortName AS PortOfLoadingName, pd.PortName AS PortOfDestinationName, fd.PortName AS FinalDestinationName,
           w.WarehouseName
    FROM @Ids x
    INNER JOIN logistics.Containers c       ON c.Id = x.Id
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN masterdata.Ports fd          ON fd.Id = c.FinalDestinationId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), FirstItem = MIN(i.ItemName), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = c.Id) ln
    ORDER BY c.Status, c.Eta, c.ContainerRef;

    -- 2: legs in route order; ProgressPct places the container on an in-progress leg (elapsed / planned duration)
    SELECT mc.ContainerId, m.Id AS MovementId, m.MovementNo,
           Seq = ROW_NUMBER() OVER (PARTITION BY mc.ContainerId ORDER BY COALESCE(m.StartDate, m.PlannedDate, CAST(m.CreatedAtUtc AS DATE)), m.Id),
           mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.Kind AS FromKind, fp.CountryCode AS FromCountry,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.Kind AS ToKind, tp.CountryCode AS ToCountry,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status,
           cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo,
           ProgressPct = CASE WHEN m.Status = 3 THEN 100
                              WHEN m.Status = 1 THEN 0
                              WHEN m.Eta IS NOT NULL AND m.StartDate IS NOT NULL AND m.Eta > m.StartDate
                                   THEN CASE WHEN DATEDIFF(DAY, m.StartDate, @Today) <= 0 THEN 0
                                             WHEN DATEDIFF(DAY, m.StartDate, @Today) * 100 / DATEDIFF(DAY, m.StartDate, m.Eta) > 95 THEN 95
                                             ELSE DATEDIFF(DAY, m.StartDate, @Today) * 100 / DATEDIFF(DAY, m.StartDate, m.Eta) END
                              ELSE 50 END,
           IsLate = CAST(CASE WHEN m.Status IN (1, 2) AND m.Eta < @Today THEN 1 ELSE 0 END AS BIT)
    FROM @Ids x
    INNER JOIN logistics.MovementContainers mc ON mc.ContainerId = x.Id
    INNER JOIN logistics.Movements m           ON m.Id = mc.MovementId AND m.Status <> 4
    INNER JOIN masterdata.MovementTypes mt     ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp             ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp             ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp           ON cp.Id = m.CarrierPartyId
    ORDER BY mc.ContainerId, Seq;
END

GO

