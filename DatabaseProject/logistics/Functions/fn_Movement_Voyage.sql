/* ================================================================== 9. A split voyage counts once in the usual next leg */

-- ONE ROW: THE VOYAGE A MOVEMENT BELONGS TO - the movement itself, or, for a movement split off another (only part of it
-- arrived, usp_Movement_SplitContainers), the first movement of its chain of splits: the copy has the same type, From, To
-- and start as the movement it came from, so the two are one voyage, which fn_Movement_NextLegHistory counts once. Fifty
-- splits deep at most (a guard below the hundred levels of recursion a statement allows; a chain of two is already rare).
CREATE   FUNCTION logistics.fn_Movement_Voyage (@MovementId INT)
RETURNS TABLE
AS
RETURN
WITH up AS (SELECT m.Id, m.SplitFromMovementId, Depth = 0
            FROM logistics.Movements m
            WHERE m.Id = @MovementId
            UNION ALL
            SELECT p.Id, p.SplitFromMovementId, up.Depth + 1
            FROM up
            INNER JOIN logistics.Movements p ON p.Id = up.SplitFromMovementId
            WHERE up.Depth < 50)
SELECT TOP (1) VoyageId = up.Id
FROM up
ORDER BY up.Depth DESC;

GO

