/* ================================================================== 2. Why a container cannot be received now */

-- (95) ONE ROW PER CONTAINER: Reason NULL when "Receive goods..." can make its draft now, else the first that applies,
-- in the words of usp_GoodsReceipt_CreateForContainer.
CREATE   FUNCTION logistics.fn_Container_ReceiveBlock (@ContainerId INT)
RETURNS TABLE
AS
RETURN
SELECT c.Id AS ContainerId,
       Reason = CAST(CASE
           WHEN c.Status = 8 THEN N'This container is cancelled.'
           WHEN c.Status IN (6, 7) OR og.Status = 2 THEN N'This container is received: its journey is over.'
           WHEN og.Status = 1 THEN N'Container ' + c.ContainerRef + N' already has a draft goods receipt. Open it instead.'
           WHEN c.Status = 1 THEN N'Confirm the container first: a draft container is not received.'
           WHEN mv.Cnt > 0 AND dl.MovementId IS NULL
               THEN c.ContainerRef + N' has not been delivered yet: complete its Delivery movement first, then receive its goods.'
           END AS NVARCHAR(400))
FROM logistics.Containers c
OUTER APPLY (SELECT TOP (1) g.Status FROM purchase.GoodsReceipts g
             WHERE g.ContainerId = c.Id AND g.Status < 3 ORDER BY g.Status DESC, g.Id DESC) og
OUTER APPLY (SELECT Cnt = COUNT(*)
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Movements m ON m.Id = mc.MovementId
             WHERE mc.ContainerId = c.Id AND m.Status <> 4) mv
OUTER APPLY logistics.fn_Container_LastDelivery(c.Id) dl
WHERE c.Id = @ContainerId;

GO

