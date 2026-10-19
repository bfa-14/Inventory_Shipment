/* ================================================================== 5. Only part of a movement arrived: a split */

-- WHY A CONTAINER CANNOT BE SPLIT OFF ITS MOVEMENT (NULL when it can), from what the caller already has of the movement
-- (its number, status and how many containers it carries): the one place of these words, for the split itself, the next
-- step's dialogs (usp_Container_NextStepPreview) and the movement page (usp_Movement_Get).
--   - only a movement in progress is split ("Only a movement in progress can be split: MOV-... is completed.");
--   - a movement carrying this container alone is completed, not split;
--   - a container that already has a LATER leg (not cancelled) stays: "previous" is the movement with the highest Id
--     below, and the copy gets a higher Id than that later leg - its place would come out wrong. The advice says what
--     taking it off a planned leg leads to: the copy comes after that leg in the travel order (fn_ContainerFitForMovement,
--     script 80), so the container cannot rejoin it and travels on with a new leg of its own once it has arrived.
CREATE   FUNCTION logistics.fn_Movement_SplitBlock
(
    @MovementId     INT,
    @MovementNo     NVARCHAR(30),
    @MovementStatus TINYINT,
    @ContainerCount INT,
    @ContainerId    INT,
    @ContainerRef   NVARCHAR(30)
)
RETURNS TABLE
AS
RETURN
SELECT Reason = CAST(CASE
           WHEN ISNULL(@MovementStatus, 0) <> 2
               THEN N'Only a movement in progress can be split: ' + @MovementNo + N' is '
                    + CASE @MovementStatus WHEN 1 THEN N'planned' WHEN 3 THEN N'completed' ELSE N'cancelled' END + N'.'
           WHEN ISNULL(@ContainerCount, 0) <= 1
               THEN @MovementNo + N' carries only ' + @ContainerRef + N': complete the movement itself.'
           WHEN l.MovementNo IS NOT NULL
               THEN @ContainerRef + N' already has the next leg ' + l.MovementNo + N' ' + l.StatusWord + N': complete '
                    + @MovementNo + N' for every container, or take it off ' + l.MovementNo + N' first'
                    + CASE WHEN l.Status = 1 THEN N' (it then gets a leg of its own once it has arrived)' ELSE N'' END
                    + N'.' END AS NVARCHAR(400))
FROM (SELECT One = 1) k
OUTER APPLY (SELECT TOP (1) m.MovementNo, m.Status,
                    StatusWord = CASE m.Status WHEN 1 THEN N'planned' WHEN 2 THEN N'in progress' ELSE N'completed' END
             FROM logistics.MovementContainers lc
             INNER JOIN logistics.Movements m ON m.Id = lc.MovementId
             WHERE lc.ContainerId = @ContainerId AND m.Id > @MovementId AND m.Status <> 4
             ORDER BY m.Id) l;

GO

