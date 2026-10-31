/* ================================================================== 2. The Cancel refuses with the function's words */

-- Re-created (83) from the body of script 82: ITS CANCEL REFUSALS ARE fn_Movement_CancelBlock'S ANSWER, thrown as it comes
-- (the header's 2.): the same numbers and the same words, in one place now, said before it asks for a reason. Start,
-- Complete and the rest of Cancel (its transaction, a Delivery's automatic drafts deleted, a split undone) are unchanged.
CREATE   PROCEDURE logistics.usp_Movement_SetStatus
    @Id         INT,
    @Action     NVARCHAR(10),
    @Date       DATE          = NULL,    -- Start: start date; Complete: end date (default today)
    @Reason     NVARCHAR(300) = NULL,    -- Cancel
    @RowVersion BINARY(8)     = NULL,
    @UserId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Action = NULLIF(LTRIM(RTRIM(@Action)), N'');
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Date IS NULL SET @Date = CAST(SYSUTCDATETIME() AS DATE);
    IF @Action IS NULL OR @Action NOT IN (N'Start', N'Complete', N'Cancel') THROW 70000, 'Action must be Start, Complete or Cancel.', 1;

    DECLARE @Status TINYINT, @StartDate DATE, @Label NVARCHAR(300), @FromPlaceId INT, @ToPlaceId INT, @MovementTypeId INT,
            @MovementNo NVARCHAR(30), @SplitFrom INT;                                                  -- (82)
    SELECT @Status = m.Status, @StartDate = m.StartDate, @MovementNo = m.MovementNo, @SplitFrom = m.SplitFromMovementId,
           @FromPlaceId = m.FromPlaceId, @ToPlaceId = m.ToPlaceId, @MovementTypeId = m.MovementTypeId,
           @Label = m.MovementNo + N' ' + mt.TypeName + N': ' + fp.PortName + N' ' + NCHAR(8594) + N' ' + tp.PortName
    FROM logistics.Movements m WITH (UPDLOCK, HOLDLOCK)
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp ON tp.Id = m.ToPlaceId
    WHERE m.Id = @Id;

    IF @Status IS NULL THROW 70006, 'Movement not found.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Movements WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 70004, 'This movement was modified by another user. Reload the page and try again.', 1;
    IF @Action = N'Start' AND @Status <> 1 THROW 70010, 'Only a planned movement can be started.', 1;
    IF @Action = N'Complete' AND @Status <> 2 THROW 70010, 'Only a movement in progress can be completed.', 1;
    IF @Action = N'Complete' AND @Date < @StartDate THROW 70000, 'The end date cannot be earlier than the start date.', 1;
    -- (83) A MOVEMENT THAT CANNOT BE CANCELLED says so first, in the words of fn_Movement_CancelBlock (already cancelled,
    -- a container offloaded, not the last leg of a container): the one place of these refusals, which the movement page
    -- also reads to disable its Cancel. Before the reason: a Cancel that can never go through does not ask for one.
    DECLARE @CancelError INT, @CancelBlock NVARCHAR(400);
    IF @Action = N'Cancel'
    BEGIN
        SELECT @CancelError = b.ErrorNumber, @CancelBlock = b.Reason FROM logistics.fn_Movement_CancelBlock(@Id) b;
        IF @CancelBlock IS NOT NULL THROW @CancelError, @CancelBlock, 1;
    END
    IF @Action = N'Cancel' AND @Reason IS NULL THROW 70000, 'A cancellation reason is required.', 1;
    -- (80) THE OWNER'S DECISION: A START AND AN ARRIVAL RECORD FACTS, never a plan (a plan is the planned date). One day of
    -- tolerance, as for the document dates: the date is the reader's, SYSUTCDATETIME() the server's in UTC.
    IF @Action = N'Start' AND @Date > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 70000, 'The start date cannot be in the future: start the movement on the day it really leaves.', 1;
    IF @Action = N'Complete' AND @Date > DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE))
        THROW 70000, 'The end date cannot be in the future: complete the movement on the day it really arrives.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.MovementContainers WHERE MovementId = @Id) AND @Action = N'Start'
        THROW 70000, 'Tick at least one container before starting.', 1;
    IF NOT EXISTS (SELECT 1 FROM logistics.MovementContainers WHERE MovementId = @Id) AND @Action = N'Complete'
        THROW 70000, 'The movement has no containers.', 1;

    DECLARE @Msg NVARCHAR(400);
    IF @Action = N'Start'
    BEGIN
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + CASE WHEN c.Status = 1 THEN N' is not confirmed yet.'
                                                                    ELSE N' is already offloaded, closed or cancelled.' END
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        WHERE mc.MovementId = @Id AND (c.Status = 1 OR c.Status >= 6)
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70010, @Msg, 1;

        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' is already travelling with movement ' + m.MovementNo + N'. Complete it first.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c         ON c.Id = mc.ContainerId
        INNER JOIN logistics.MovementContainers o ON o.ContainerId = mc.ContainerId AND o.MovementId <> @Id
        INNER JOIN logistics.Movements m          ON m.Id = o.MovementId AND m.Status = 2
        WHERE mc.MovementId = @Id
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70012, @Msg, 1;

        -- the place rules (script 53): the previous movement of every container is completed (70016), then every
        -- container fits the movement's From, To and stage (70015) - the rules of Save, fn_ContainerFitForMovement
        -- (81) each container's previous movement read for itself (fn_Container_PreviousMovement, the "previous" of
        -- fn_ContainerPlaceForMovement): through the function over every container, the search for the first refusal
        -- in ref order walked all the containers of the database - 18 s a Start on 50,000 containers.
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N': the previous movement ' + pm.MovementNo + N' (' + pf.PortName
                              + N' ' + NCHAR(8594) + N' ' + pt.PortName + N') is not completed yet.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        CROSS APPLY logistics.fn_Container_PreviousMovement(mc.ContainerId, @Id) pm
        INNER JOIN masterdata.Ports pf    ON pf.Id = pm.FromPlaceId
        INNER JOIN masterdata.Ports pt    ON pt.Id = pm.ToPlaceId
        WHERE mc.MovementId = @Id AND pm.Status <> 3
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70016, @Msg, 1;

        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' cannot leave from ' + f.PortName + N'. ' + p.Reason
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        INNER JOIN logistics.fn_ContainerFitForMovement(@Id, @FromPlaceId, @ToPlaceId, @MovementTypeId) p ON p.ContainerId = mc.ContainerId
        INNER JOIN masterdata.Ports f     ON f.Id = @FromPlaceId
        WHERE mc.MovementId = @Id AND p.Fits = 0
        ORDER BY c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70015, @Msg, 1;

        -- (80) NOT BEFORE THE PREVIOUS LEG ENDED (70018): a container cannot set off from a place before it got there.
        -- The previous movement is completed here (70016 above); its end date is the earliest start.
        SELECT TOP (1) @Msg = N'Container ' + c.ContainerRef + N' cannot start ' + @MovementNo + N' before ' + pm.MovementNo
                              + N' reached ' + tp.PortName + N' on ' + CONVERT(NVARCHAR(10), pm.EndDate, 103) + N'.'
        FROM logistics.MovementContainers mc
        INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
        CROSS APPLY logistics.fn_Container_PreviousMovement(mc.ContainerId, @Id) pm                      -- (81)
        INNER JOIN masterdata.Ports tp    ON tp.Id = pm.ToPlaceId
        WHERE mc.MovementId = @Id AND pm.EndDate > @Date
        ORDER BY pm.EndDate DESC, c.ContainerRef;
        IF @Msg IS NOT NULL THROW 70018, @Msg, 1;
    END
    -- (83) Cancel: a container offloaded and the last-leg rule (81) are fn_Movement_CancelBlock's, checked above.

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE logistics.Movements
        SET Status = CASE @Action WHEN N'Start' THEN 2 WHEN N'Complete' THEN 3 ELSE 4 END,
            StartDate = CASE WHEN @Action = N'Start' THEN @Date ELSE StartDate END,
            EndDate = CASE WHEN @Action = N'Complete' THEN @Date ELSE EndDate END,
            StartedAtUtc = CASE WHEN @Action = N'Start' THEN SYSUTCDATETIME() ELSE StartedAtUtc END,
            StartedBy = CASE WHEN @Action = N'Start' THEN @UserId ELSE StartedBy END,
            CompletedAtUtc = CASE WHEN @Action = N'Complete' THEN SYSUTCDATETIME() ELSE CompletedAtUtc END,
            CompletedBy = CASE WHEN @Action = N'Complete' THEN @UserId ELSE CompletedBy END,
            CancelledAtUtc = CASE WHEN @Action = N'Cancel' THEN SYSUTCDATETIME() ELSE CancelledAtUtc END,
            CancelledBy = CASE WHEN @Action = N'Cancel' THEN @UserId ELSE CancelledBy END,
            CancelReason = CASE WHEN @Action = N'Cancel' THEN @Reason ELSE CancelReason END,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        SELECT mc.ContainerId, N'Event',
               LEFT(CASE @Action WHEN N'Start' THEN N'Started ' WHEN N'Complete' THEN N'Arrived / completed ' ELSE N'Cancelled ' END
                    + @Label + N' on ' + CONVERT(NVARCHAR(10), @Date, 23) + ISNULL(N' - ' + @Reason, N''), 500),
               @UserId
        FROM logistics.MovementContainers mc WHERE mc.MovementId = @Id;

        -- (65) RULE 22: CANCELLING A COMPLETED DELIVERY TAKES BACK THE DRAFT GOODS RECEIPTS ITS COMPLETION CREATED (IsAuto,
        -- MovementId = this movement), edited or not - the cancel dialog names the edited ones first (usp_Movement_Get).
        -- A draft made by hand is kept. A posted receipt made its container Offloaded, so the check above refused the
        -- cancel. The same plain deletes as usp_GoodsReceipt_Delete: a draft has no stock, number or cost to undo.
        IF @Action = N'Cancel' AND @Status = 3
        BEGIN
            DECLARE @AutoDrafts TABLE (Id INT NOT NULL PRIMARY KEY, ContainerId INT NOT NULL);
            INSERT INTO @AutoDrafts (Id, ContainerId)
            SELECT g.Id, g.ContainerId
            FROM purchase.GoodsReceipts g WITH (UPDLOCK, HOLDLOCK)
            WHERE g.MovementId = @Id AND g.IsAuto = 1 AND g.Status = 1;

            IF EXISTS (SELECT 1 FROM @AutoDrafts)
            BEGIN
                DELETE m FROM purchase.GoodsReceiptInvoiceMatches m
                INNER JOIN purchase.GoodsReceiptLines l ON l.Id = m.GoodsReceiptLineId
                INNER JOIN @AutoDrafts d                ON d.Id = l.GoodsReceiptId;
                DELETE f FROM purchase.GoodsReceiptFiles f INNER JOIN @AutoDrafts d ON d.Id = f.GoodsReceiptId;
                DELETE l FROM purchase.GoodsReceiptLines l INNER JOIN @AutoDrafts d ON d.Id = l.GoodsReceiptId;
                DELETE a FROM purchase.GoodsReceiptAudit a INNER JOIN @AutoDrafts d ON d.Id = a.GoodsReceiptId;
                DELETE g FROM purchase.GoodsReceipts g INNER JOIN @AutoDrafts d ON d.Id = g.Id;

                INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
                SELECT d.ContainerId, N'Event', LEFT(N'Draft goods receipt removed: movement ' + @MovementNo + N' cancelled', 500), @UserId
                FROM @AutoDrafts d;
            END
        END

        -- (82) CANCELLING A SPLIT-OFF MOVEMENT UNDOES THE SPLIT (usp_Movement_SplitContainers): its containers go back onto
        -- the movement they were split from (fn_Movement_SplitUndoTarget: that one, or where its own undone split sent its
        -- containers), whatever its status, as if they had never been split off - in progress they travel on with it,
        -- completed they arrived with it, cancelled its cancellation applies to them too. Their rows of the container list,
        -- their charges filed under this movement and their documents filed under it go back with them (a file other
        -- containers share keeps their records where they are: one record per container); this one ends cancelled, and
        -- empty. Every rule above still holds: only the last leg of each container (none has a later leg), never an
        -- offloaded one, a completed Delivery's automatic drafts deleted just above - put back onto a completed Delivery
        -- they have none (Delivered, not received: Receive goods... on each container). That movement is locked like
        -- this one (a split always points to a lower Id, so the locks are always taken in the same order).
        DECLARE @BackTo INT, @BackToNo NVARCHAR(30), @Moved INT = 0, @Refs NVARCHAR(1000);
        DECLARE @Back TABLE (ContainerId INT NOT NULL PRIMARY KEY, ContainerRef NVARCHAR(30) NULL);
        IF @Action = N'Cancel' AND @SplitFrom IS NOT NULL
        BEGIN
            SELECT @BackTo = t.MovementId FROM logistics.fn_Movement_SplitUndoTarget(@Id) t;
            SELECT @BackToNo = m.MovementNo FROM logistics.Movements m WITH (UPDLOCK, HOLDLOCK) WHERE m.Id = @BackTo;

            INSERT INTO @Back (ContainerId, ContainerRef)
            SELECT mc.ContainerId, c.ContainerRef
            FROM logistics.MovementContainers mc
            INNER JOIN logistics.Containers c ON c.Id = mc.ContainerId
            WHERE mc.MovementId = @Id AND @BackToNo IS NOT NULL;
            SET @Moved = @@ROWCOUNT;
        END

        IF @Moved > 0
        BEGIN
            -- 1. their rows (each row as it is; a container already on that movement keeps the row it has there: never
            -- twice), their charges and their documents filed under this movement
            UPDATE mc SET MovementId = @BackTo
            FROM logistics.MovementContainers mc
            WHERE mc.MovementId = @Id
              AND NOT EXISTS (SELECT 1 FROM logistics.MovementContainers o WHERE o.MovementId = @BackTo AND o.ContainerId = mc.ContainerId);
            DELETE FROM logistics.MovementContainers WHERE MovementId = @Id;

            UPDATE ch SET MovementId = @BackTo, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            FROM logistics.ContainerCharges ch
            INNER JOIN @Back b ON b.ContainerId = ch.ContainerId
            WHERE ch.MovementId = @Id;

            UPDATE a SET MovementId = @BackTo
            FROM logistics.ContainerAttachments a
            INNER JOIN @Back b ON b.ContainerId = a.ContainerId
            WHERE a.MovementId = @Id;

            -- that movement changed (containers came back to it): its RowVersion moves, a page left open on it reloads
            UPDATE logistics.Movements SET UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @BackTo;

            -- 2. AUDIT on both movements and on each container (the first 20 refs, then "and N more")
            SELECT @Refs = STRING_AGG(CAST(x.ContainerRef AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY LEN(x.ContainerRef), x.ContainerRef)
            FROM (SELECT TOP (20) ContainerRef FROM @Back ORDER BY LEN(ContainerRef), ContainerRef) x;
            IF @Moved > 20 SET @Refs = @Refs + N' and ' + CAST(@Moved - 20 AS NVARCHAR(12)) + N' more';

            INSERT INTO logistics.MovementAudit (MovementId, Action, Details, UserId)
            VALUES (@Id, N'Split undone', LEFT(N'Split undone: ' + @Refs + N' back on ' + @BackToNo, 1000), @UserId),
                   (@BackTo, N'Split undone', LEFT(N'Back from ' + @MovementNo + N' (split undone): ' + @Refs, 1000), @UserId);

            INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
            SELECT b.ContainerId, N'Event',
                   LEFT(N'Moved back from ' + @MovementNo + N' to ' + @BackToNo + N': ' + @MovementNo + N' cancelled (split undone)', 500), @UserId
            FROM @Back b;
        END

        DECLARE @Cid INT;
        DECLARE ctn CURSOR LOCAL FAST_FORWARD FOR SELECT ContainerId FROM logistics.MovementContainers WHERE MovementId = @Id
                                                  UNION SELECT ContainerId FROM @Back;              -- (82) and the ones put back
        OPEN ctn;
        FETCH NEXT FROM ctn INTO @Cid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC logistics.usp_Container_RefreshStatus @Cid;
            FETCH NEXT FROM ctn INTO @Cid;
        END
        CLOSE ctn;
        DEALLOCATE ctn;

        -- (82) A SPLIT UNDONE ANSWERS ONE ROW (the API's notification), inside the transaction like the split's own
        -- answer: the movement they went back to, as it is now, and the containers put back on it (the first ten).
        -- No other call of this procedure returns a row.
        IF @Moved > 0
            SELECT MovementId = t.Id, t.MovementNo, t.Status, t.EndDate, ToName = tp.PortName, mt.Stage,
                   ContainerCount = @Moved,
                   ContainerRefs = (SELECT STRING_AGG(CAST(x.ContainerRef AS NVARCHAR(MAX)), N',') WITHIN GROUP (ORDER BY LEN(x.ContainerRef), x.ContainerRef)
                                    FROM (SELECT TOP (10) ContainerRef FROM @Back ORDER BY LEN(ContainerRef), ContainerRef) x)
            FROM logistics.Movements t
            INNER JOIN masterdata.MovementTypes mt ON mt.Id = t.MovementTypeId
            INNER JOIN masterdata.Ports tp         ON tp.Id = t.ToPlaceId
            WHERE t.Id = @BackTo;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

