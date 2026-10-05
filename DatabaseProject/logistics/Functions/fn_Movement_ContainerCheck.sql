/* ================================================================== 2. The checks of a movement's Save, per container */

-- Re-created (49) from the body of script 46: + @ToPlaceId and @MovementTypeId, the place rules of
-- fn_ContainerFitForMovement (PlaceName is the port of loading of a container that never moved).
-- Every container with the columns of the picker and the checks of usp_Movement_Save for @MovementId (NULL = a new,
-- planned movement) leaving from @FromPlaceId for @ToPlaceId with the type @MovementTypeId. For a container not on the movement: offloaded / closed / cancelled,
-- in progress: not confirmed, travelling with another movement, then the place rule (the order of Save). For a
-- container on the movement (OnMovement = 1): the checks that apply to a kept one (travelling, place).
-- CanAdd = no Reason. Note (only without a Reason): never moved (or no port of loading), on its way here, draft of a
-- planned movement.
CREATE   FUNCTION logistics.fn_Movement_ContainerCheck (@MovementId INT, @FromPlaceId INT, @ToPlaceId INT, @MovementTypeId INT)
RETURNS TABLE
AS
RETURN
SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, c.SealNo, ct.TypeCode AS ContainerTypeCode,
       OrderNumbers = CASE WHEN ISNULL(po.OrderCount, 0) = 0 THEN NULL
                           WHEN po.OrderCount = 1 THEN po.FirstOrder
                           ELSE po.FirstOrder + N' +' + CAST(po.OrderCount - 1 AS NVARCHAR(10)) END,
       SupplierNames = CASE WHEN ISNULL(po.SupplierCount, 0) = 0 THEN NULL
                            WHEN po.SupplierCount = 1 THEN po.FirstSupplier
                            ELSE po.FirstSupplier + N' +' + CAST(po.SupplierCount - 1 AS NVARCHAR(10)) END,
       ItemSummary = CASE WHEN ISNULL(ln.ItemCount, 0) = 0 THEN NULL
                          WHEN ln.ItemCount = 1 THEN ln.FirstItem
                          ELSE N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
       Pieces = ISNULL(ln.Qty, 0),
       c.Status, c.Eta, c.OrderDate, c.BlNo, c.VesselName,
       p.PlaceId, p.PlaceName, p.PreviousMovementId, p.PreviousMovementNo, p.PreviousStatus, p.PortOfLoadingName,
       OnMovement = CAST(CASE WHEN mc.Id IS NULL THEN 0 ELSE 1 END AS BIT),
       CanAdd = CAST(CASE WHEN r.Reason IS NULL THEN 1 ELSE 0 END AS BIT),
       r.Reason,
       Note = CAST(CASE WHEN r.Reason IS NULL THEN NULLIF(CONCAT_WS(N' ',
                  p.Note,
                  CASE WHEN p.PreviousStatus IN (1, 2)
                       THEN N'On its way here with ' + p.PreviousMovementNo + N': this movement can start once it is completed.' END,
                  CASE WHEN mv.MovementStatus = 1 AND c.Status = 1 THEN N'Draft: confirm it before the movement starts.' END), N'') END
              AS NVARCHAR(300))
FROM logistics.Containers c
INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
INNER JOIN logistics.fn_ContainerFitForMovement(@MovementId, @FromPlaceId, @ToPlaceId, @MovementTypeId) p ON p.ContainerId = c.Id
CROSS JOIN (SELECT MovementStatus = ISNULL((SELECT m.Status FROM logistics.Movements m WHERE m.Id = @MovementId), 1)) mv
LEFT JOIN logistics.MovementContainers mc ON mc.MovementId = @MovementId AND mc.ContainerId = c.Id
OUTER APPLY (SELECT OrderCount = COUNT(DISTINCT cl.PurchaseOrderId), SupplierCount = COUNT(DISTINCT d.SupplierId),
                    FirstOrder = MIN(d.DocumentNumber), FirstSupplier = MIN(sp.PartyName)
             FROM logistics.ContainerLines cl
             INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
             INNER JOIN masterdata.Parties sp        ON sp.Id = d.SupplierId
             WHERE cl.ContainerId = c.Id) po
OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), Qty = SUM(cl.QuantityBase), FirstItem = MIN(i.ItemName)
             FROM logistics.ContainerLines cl
             INNER JOIN inventory.Items i ON i.Id = cl.ItemId
             WHERE cl.ContainerId = c.Id) ln
OUTER APPLY (SELECT TOP (1) m.MovementNo
             FROM logistics.MovementContainers o
             INNER JOIN logistics.Movements m ON m.Id = o.MovementId AND m.Status = 2
             WHERE o.ContainerId = c.Id AND (@MovementId IS NULL OR o.MovementId <> @MovementId)
             ORDER BY m.Id DESC) tr
CROSS APPLY (SELECT Reason = CAST(CASE
                 WHEN mc.Id IS NULL AND c.Status >= 6 THEN N'Already offloaded, closed or cancelled.'
                 WHEN mc.Id IS NULL AND mv.MovementStatus = 2 AND c.Status = 1 THEN N'Not confirmed yet.'
                 WHEN mv.MovementStatus = 2 AND tr.MovementNo IS NOT NULL THEN N'Travelling with movement ' + tr.MovementNo + N'.'
                 WHEN p.Fits = 0 THEN p.Reason END
             AS NVARCHAR(300))) r;

GO

