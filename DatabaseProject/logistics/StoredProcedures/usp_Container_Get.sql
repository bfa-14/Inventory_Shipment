CREATE   PROCEDURE logistics.usp_Container_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT c.Id, c.DocumentTypeId, c.ContainerRef, c.ContainerNo,
           c.ContainerTypeId, ct.TypeCode AS ContainerTypeCode, ct.TypeName AS ContainerTypeName,
           TypeMaxUnits = ct.MaxUnits, ct.MaxWeightKg, ct.MaxVolumeCbm,
           c.SealNo, c.CustomsSealNo, c.Description,
           c.OrderDate, c.OrderMonthKey, OrderMonth = FORMAT(c.OrderDate, N'MMM-yyyy', N'en-US'),
           c.ShippingMethod, c.CountryOfOrigin,
           c.ForwarderId, fw.PartyName AS ForwarderName, c.TransporterId, tr.PartyName AS TransporterName,
           c.ShippingLine, c.VesselName, c.VoyageNo, c.BookingNo,
           c.PortOfLoadingId, pl.PortName AS PortOfLoadingName, pl.CountryCode AS PortOfLoadingCountry,
           c.PortOfDestinationId, pd.PortName AS PortOfDestinationName, pd.CountryCode AS PortOfDestinationCountry,
           c.FinalDestinationId, fd.PortName AS FinalDestinationName,
           c.DispatchDate, c.Eta, c.FreeDays, c.LastFreeDay, c.GrossWeightKg, c.VolumeCbm, c.Packages,
           c.BlNo, c.BlDate, c.BlNotes,
           c.MaxUnits, c.TotalLines, c.TotalAllocatedBase, c.TotalReceivedBase, c.TotalOilQty, c.UtilizationPct,
           RemainingCapacityBase = CASE WHEN c.MaxUnits IS NOT NULL THEN c.MaxUnits - c.TotalAllocatedBase END,
           IsOverCapacity = CASE WHEN c.MaxUnits IS NOT NULL AND c.TotalAllocatedBase > c.MaxUnits THEN 1 ELSE 0 END,
           c.BranchId, b.BranchCode, b.BranchName, c.WarehouseId, w.WarehouseCode, w.WarehouseName,
           c.TruckNo, c.WaybillNo, c.DeclarationNo, c.FeriNo,
           c.ActualPortArrival, c.BorderCrossingDate, c.CustomsReleaseDate,
           DaysAtPort = CASE WHEN c.ActualPortArrival IS NOT NULL
                             THEN DATEDIFF(DAY, c.ActualPortArrival, ISNULL(c.OffloadedDate, CAST(SYSUTCDATETIME() AS DATE))) END,
           c.OffloadedDate, c.OffloadedAtUtc, c.OffloadedBy, ou.FullName AS OffloadedByName,
           c.Status, c.StatusNote, c.CurrentLocation, c.Notes,
           c.ConfirmedAtUtc, c.ConfirmedBy, fu.FullName AS ConfirmedByName,
           c.ClosedAtUtc, c.ClosedBy, ku.FullName AS ClosedByName,
           c.CancelledAtUtc, c.CancelledBy, xu.FullName AS CancelledByName, c.CancelReason,
           c.CreatedAtUtc, c.CreatedBy, cu.FullName AS CreatedByName,
           c.UpdatedAtUtc, c.UpdatedBy, uu.FullName AS UpdatedByName, c.RowVersion
    FROM logistics.Containers c
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    INNER JOIN masterdata.Branches b        ON b.Id = c.BranchId
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    LEFT  JOIN masterdata.Parties fw        ON fw.Id = c.ForwarderId
    LEFT  JOIN masterdata.Parties tr        ON tr.Id = c.TransporterId
    LEFT  JOIN masterdata.Ports pl          ON pl.Id = c.PortOfLoadingId
    LEFT  JOIN masterdata.Ports pd          ON pd.Id = c.PortOfDestinationId
    LEFT  JOIN masterdata.Ports fd          ON fd.Id = c.FinalDestinationId
    LEFT  JOIN security.Users ou ON ou.Id = c.OffloadedBy
    LEFT  JOIN security.Users fu ON fu.Id = c.ConfirmedBy
    LEFT  JOIN security.Users ku ON ku.Id = c.ClosedBy
    LEFT  JOIN security.Users xu ON xu.Id = c.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = c.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = c.UpdatedBy
    WHERE c.Id = @Id;

    SELECT ci.Id, ci.ContainerId, ci.PurchaseDocumentId, d.DocumentNumber, d.DocumentDate, d.Status AS InvoiceStatus,
           d.ReceiptMode, d.SupplierId, sp.PartyCode AS SupplierCode, sp.PartyName AS SupplierName,
           d.CurrencyId, cur.CurrencyCode, cur.Symbol AS CurrencySymbol, d.ExchangeRate,
           d.SupplierReference, d.ExporterReference, d.CommercialInvoiceNo,
           d.WarehouseId, w.WarehouseCode, w.WarehouseName,
           TotalQtyBase       = x.Total,
           AllocatedHereBase  = ISNULL(x.Here, 0),
           AllocatedTotalBase = ISNULL(x.Everywhere, 0),
           RemainingBase      = x.Total - ISNULL(x.Everywhere, 0),
           d.TotalAmount, d.TotalAmountBase, d.TotalLandedCostBase
    FROM logistics.ContainerInvoices ci
    INNER JOIN purchase.PurchaseDocuments d ON d.Id = ci.PurchaseDocumentId
    INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
    INNER JOIN masterdata.Currencies cur    ON cur.Id = d.CurrencyId
    INNER JOIN masterdata.Warehouses w      ON w.Id = d.WarehouseId
    CROSS APPLY (SELECT Total = ISNULL(SUM(l.QuantityBase), 0),
                        Here = ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl WHERE cl.PurchaseDocumentId = d.Id AND cl.ContainerId = @Id), 0),
                        Everywhere = ISNULL((SELECT SUM(cl.QuantityBase) FROM logistics.ContainerLines cl
                                             INNER JOIN logistics.Containers c2 ON c2.Id = cl.ContainerId
                                             WHERE cl.PurchaseDocumentId = d.Id AND c2.Status <> 8), 0)
                 FROM purchase.PurchaseDocumentLines l WHERE l.DocumentId = d.Id) x
    WHERE ci.ContainerId = @Id
    ORDER BY d.DocumentNumber;

    SELECT cl.Id, cl.ContainerId, cl.LineNumber, cl.PurchaseDocumentId, d.DocumentNumber AS InvoiceNumber,
           d.CommercialInvoiceNo, sp.PartyName AS SupplierName,
           cl.PurchaseLineId, pl.LineNumber AS InvoiceLineNumber,
           cl.ItemId, i.ItemCode, i.ItemName, i.Model, br.BrandName,
           cl.ItemUnitId, ut.UnitTypeName, cl.PackingFormula,
           cl.Quantity, cl.QuantityBase, cl.OilIncluded, cl.OilQtyPerUnit, cl.TotalOilQty,
           cl.ReceivedQuantityBase, cl.VarianceReason, cl.Notes,
           InvoiceQtyBase        = pl.QuantityBase,
           AllocatedElsewhereBase = ISNULL(other.Qty, 0),
           AvailableBase         = pl.QuantityBase - ISNULL(other.Qty, 0),
           UnitCostBase          = pl.UnitCostBase, FobCostBase = pl.FobCostBase,
           OnHandBase            = inventory.fn_StockOnHand(cl.ItemId, pl.WarehouseId),
           pl.WarehouseId, w.WarehouseCode, w.WarehouseName
    FROM logistics.ContainerLines cl
    INNER JOIN purchase.PurchaseDocuments d      ON d.Id = cl.PurchaseDocumentId
    INNER JOIN masterdata.Parties sp             ON sp.Id = d.SupplierId
    INNER JOIN purchase.PurchaseDocumentLines pl ON pl.Id = cl.PurchaseLineId
    INNER JOIN masterdata.Warehouses w           ON w.Id = pl.WarehouseId
    INNER JOIN inventory.Items i                 ON i.Id = cl.ItemId
    INNER JOIN masterdata.Brands br              ON br.Id = i.BrandId
    INNER JOIN inventory.ItemUnits iu            ON iu.Id = cl.ItemUnitId
    INNER JOIN masterdata.UnitTypes ut           ON ut.Id = iu.UnitTypeId
    OUTER APPLY (SELECT Qty = SUM(o.QuantityBase) FROM logistics.ContainerLines o
                 INNER JOIN logistics.Containers oc ON oc.Id = o.ContainerId
                 WHERE o.PurchaseLineId = cl.PurchaseLineId AND o.ContainerId <> @Id AND oc.Status <> 8) other
    WHERE cl.ContainerId = @Id
    ORDER BY cl.LineNumber;

    SELECT e.Id, e.ContainerId, e.EventType, e.EventDate, e.PortId, p.PortName, e.LocationText, e.Notes,
           e.CreatedAtUtc, e.CreatedBy, u.FullName AS CreatedByName
    FROM logistics.ContainerEvents e
    LEFT JOIN masterdata.Ports p ON p.Id = e.PortId
    LEFT JOIN security.Users u   ON u.Id = e.CreatedBy
    WHERE e.ContainerId = @Id
    ORDER BY e.EventDate DESC, e.Id DESC;

    SELECT f.Id, f.ContainerId, f.AttachmentTypeId, at.Category, at.SubType, f.FileName, f.ContentType, f.SizeBytes,
           f.Note, f.DocumentDate, f.CreatedAtUtc, f.CreatedBy, u.FullName AS CreatedByName
    FROM logistics.ContainerFiles f
    LEFT JOIN masterdata.AttachmentTypes at ON at.Id = f.AttachmentTypeId
    LEFT JOIN security.Users u ON u.Id = f.CreatedBy
    WHERE f.ContainerId = @Id
    ORDER BY f.CreatedAtUtc DESC;

    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM logistics.ContainerAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.ContainerId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END

GO

