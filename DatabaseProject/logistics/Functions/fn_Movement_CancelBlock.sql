/* ================================================================== 1. Can a movement be cancelled, and why not */

-- THE ONE PLACE THAT SAYS WHETHER A MOVEMENT CAN BE CANCELLED NOW and, when it cannot, the first refusal of its Cancel:
-- the number and the words usp_Movement_SetStatus throws (it throws this row as it comes), in its order (the header's 1.).
-- One row per movement: ErrorNumber and Reason NULL when the Cancel would go through. Read by the Cancel itself and by
-- usp_Movement_Get, whose page disables its "Cancel..." with the reason. Each check reads the movement's own containers
-- and their later legs only (IX_MovementContainers_ContainerMovement).
CREATE   FUNCTION logistics.fn_Movement_CancelBlock (@MovementId INT)
RETURNS TABLE
AS
RETURN
SELECT MovementId = mv.Id,
       ErrorNumber = CASE WHEN mv.Status = 4 OR rc.Reason IS NOT NULL OR ll.Reason IS NOT NULL THEN 70010 END,
       Reason = CAST(CASE WHEN mv.Status = 4 THEN N'The movement is already cancelled.'
                          ELSE COALESCE(rc.Reason, ll.Reason) END AS NVARCHAR(400))
FROM logistics.Movements mv
-- A CONTAINER RECEIVED OR CLOSED (6 Offloaded, 7 Closed) on a movement in progress or completed: its route can no longer
-- change. A planned movement never moved it: it may still be cancelled.
OUTER APPLY (SELECT TOP (1) Reason = N'Container ' + c.ContainerRef + N' is already offloaded: its route can no longer change.'
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
             WHERE mc.MovementId = mv.Id AND c.Status IN (6, 7) AND mv.Status IN (2, 3)
             ORDER BY c.ContainerRef) rc
-- (81) ONLY THE LAST LEG OF A CONTAINER CAN BE CANCELLED: a later leg (planned, in progress or completed) left from this
-- one's To, so cancelling this one would leave the container at a place it never reached and break its chain of places.
-- The latest one is named: it is the one to cancel first. A PLANNED leg that a later leg already passed (started or
-- completed after it: data of before script 80) never happened and is no part of the chain: it may be cancelled -
-- Delete refuses it once a charge or a file names it.
OUTER APPLY (SELECT TOP (1) Reason = mv.MovementNo + N' is not the last leg of ' + c.ContainerRef + N': cancel ' + l.MovementNo + N' first.'
             FROM logistics.MovementContainers mc
             INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
             CROSS APPLY (SELECT TOP (1) m.MovementNo
                          FROM logistics.MovementContainers lc
                          INNER JOIN logistics.Movements m ON m.Id = lc.MovementId
                          WHERE lc.ContainerId = mc.ContainerId AND m.Id > mv.Id AND m.Status <> 4
                          ORDER BY m.Id DESC) l
             WHERE mc.MovementId = mv.Id
               AND NOT (mv.Status = 1 AND EXISTS (SELECT 1
                                                  FROM logistics.MovementContainers pc
                                                  INNER JOIN logistics.Movements pm ON pm.Id = pc.MovementId
                                                  WHERE pc.ContainerId = mc.ContainerId AND pm.Id > mv.Id AND pm.Status IN (2, 3)))
             ORDER BY LEN(c.ContainerRef), c.ContainerRef) ll
WHERE mv.Id = @MovementId;

GO

