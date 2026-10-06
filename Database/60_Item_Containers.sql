SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ==================================================================================================
   60: Item containers
   --------------------------------------------------------------------------------------------------
   The item card's "Containers" quick link: every container that carries the item, newest first, with
   how much of THIS item it was loaded with and how much has been received from it.

     inventory.usp_Item_Containers   @ItemId -> one row per container (its lines of the item added up)

   ON THE WAY is counted from Confirmed to Cleared (statuses 2-5) only: a draft has not shipped, and
   an offloaded, closed or cancelled container is no longer bringing anything.
   ================================================================================================== */

IF OBJECT_ID(N'logistics.ContainerLines', N'U') IS NULL
BEGIN
    RAISERROR ('The logistics scripts must run before script 60.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE inventory.usp_Item_Containers
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

PRINT 'Script 60 applied: item containers.';
GO

SET NOEXEC OFF;
GO
