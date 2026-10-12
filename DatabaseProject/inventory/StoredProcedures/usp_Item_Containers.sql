CREATE   PROCEDURE inventory.usp_Item_Containers
    @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, c.Status AS StatusCode,
           ContainerTypeName = ct.TypeName, c.OrderDate, c.DispatchDate, c.Eta, c.OffloadedDate,
           br.BranchName, w.WarehouseName,
           PurchaseOrderId = c.PurchaseOrderId, PurchaseOrderNumber = po.DocumentNumber,
           x.LoadedBase, x.ReceivedBase,
           OnTheWayBase = CASE WHEN c.Status BETWEEN 2 AND 5 AND x.LoadedBase > x.ReceivedBase THEN x.LoadedBase - x.ReceivedBase ELSE 0 END
    FROM logistics.Containers c
    CROSS APPLY (SELECT LoadedBase = SUM(l.QuantityBase), ReceivedBase = SUM(ISNULL(l.ReceivedQuantityBase, 0))
                 FROM logistics.ContainerLines l
                 WHERE l.ContainerId = c.Id AND l.ItemId = @ItemId) x
    LEFT JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    LEFT JOIN masterdata.Branches br       ON br.Id = c.BranchId
    LEFT JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    LEFT JOIN purchase.PurchaseDocuments po ON po.Id = c.PurchaseOrderId
    WHERE x.LoadedBase IS NOT NULL
    ORDER BY c.OrderDate DESC, c.Id DESC;
END

GO

