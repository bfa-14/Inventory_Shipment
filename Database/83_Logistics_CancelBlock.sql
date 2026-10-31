SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 83: LOGISTICS - A MOVEMENT THAT CANNOT BE CANCELLED SAYS WHY, BEFORE THE CLICK

   The end-to-end test of shipment phase 3: the Cancel dialog of a movement opened - and even said where the containers of
   a split-off movement would go back - when the Cancel was then refused: a container on it had a later leg
   ("MOV-2026-000091 is not the last leg of KTG-2026-0133: cancel MOV-2026-000092 first.") or was already received
   ("Container KTG-2026-0041 is already offloaded: its route can no longer change."). The project's rule: a button stays
   visible but disabled, with the reason; it is hidden only without the permission. So the movement page needs the
   refusal before the click, in the Cancel's own words.

     1. NEW logistics.fn_Movement_CancelBlock: THE ONE PLACE that says whether a movement can be cancelled now and, when it
        cannot, the first refusal of its Cancel - its number and its words, in the Cancel's order. One row per movement;
        ErrorNumber and Reason NULL when the Cancel would go through.
          70010 "The movement is already cancelled."
          70010 "Container KTG-2026-0041 is already offloaded: its route can no longer change."   a container received
                (6 Offloaded) or closed (7) on a movement in progress or completed, the first in ref order. A planned
                movement never moved it: the Cancel goes through.
          70010 "MOV-2026-000091 is not the last leg of KTG-2026-0133: cancel MOV-2026-000092 first."   (script 81) a
                later leg of one of its containers, planned, in progress or completed (a cancelled one does not count);
                the container first by the length of its ref, then its ref, and the latest of its later legs named. A
                PLANNED movement that a later leg already passed (started or completed after it: data of before script 80)
                is no part of that container's chain: that container does not refuse it.
        What the Cancel asks of its caller is not the movement's state and stays in usp_Movement_SetStatus: 70006
        "Movement not found.", 70004 changed by another user, 70000 "A cancellation reason is required." (the dialog asks
        for it, and the API refuses a blank one itself before it calls).
     2. logistics.usp_Movement_SetStatus: its Cancel refusals ARE the function's answer, thrown as it comes - the same
        numbers and the same words as before, in one place now. One order changes, never seen through the API (which
        refuses a blank reason before it calls): the refusal comes before "A cancellation reason is required." - a Cancel
        that can never go through says so before it asks for a reason, as the page does. Start, Complete and all that
        follows the checks (the transaction, a Delivery's automatic drafts deleted, a split undone) are unchanged.
     3. logistics.usp_Movement_Get: + CanCancel and CancelBlockedReason (header), from the function: the movement page
        disables its "Cancel..." with the reason (a tooltip; on a phone, under the label in its menu).

   Not changed: logistics.usp_Movement_Search - the Movements list offers Start... and Complete..., no Cancel.
   Re-created from their current bodies: logistics.usp_Movement_SetStatus (82), logistics.usp_Movement_Get (82).
   New: logistics.fn_Movement_CancelBlock. No new table, column, permission or error number (70010).

   Requires script 82 (Schema.sql runs it first). Idempotent, additive: re-applied at every API start-up, and builds a
   brand-new empty database.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'logistics.fn_Movement_SplitUndoTarget') IS NULL                    -- 82
   OR OBJECT_ID(N'logistics.MovementAudit', N'U') IS NULL                          -- 82
   OR COL_LENGTH(N'logistics.Movements', N'SplitFromMovementId') IS NULL           -- 82
    THROW 70000, 'Script 83 requires script 82: apply it first.', 1;
GO

/* ================================================================== 1. Can a movement be cancelled, and why not */

-- THE ONE PLACE THAT SAYS WHETHER A MOVEMENT CAN BE CANCELLED NOW and, when it cannot, the first refusal of its Cancel:
-- the number and the words usp_Movement_SetStatus throws (it throws this row as it comes), in its order (the header's 1.).
-- One row per movement: ErrorNumber and Reason NULL when the Cancel would go through. Read by the Cancel itself and by
-- usp_Movement_Get, whose page disables its "Cancel..." with the reason. Each check reads the movement's own containers
-- and their later legs only (IX_MovementContainers_ContainerMovement).
CREATE OR ALTER FUNCTION logistics.fn_Movement_CancelBlock (@MovementId INT)
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

/* ================================================================== 2. The Cancel refuses with the function's words */

-- Re-created (83) from the body of script 82: ITS CANCEL REFUSALS ARE fn_Movement_CancelBlock'S ANSWER, thrown as it comes
-- (the header's 2.): the same numbers and the same words, in one place now, said before it asks for a reason. Start,
-- Complete and the rest of Cancel (its transaction, a Delivery's automatic drafts deleted, a split undone) are unchanged.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_SetStatus
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

/* ================================================================== 3. The movement page: can it be cancelled, and why not */

-- Re-created (83) from the body of script 82: + whether the movement can be cancelled now and, when it cannot, the first
-- refusal of its Cancel (header: CanCancel, CancelBlockedReason - fn_Movement_CancelBlock, the Cancel's own words). Nothing
-- else changes.
CREATE OR ALTER PROCEDURE logistics.usp_Movement_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;

    -- (82) the movement's number, status and containers: whether each of them can be split off (fn_Movement_SplitBlock)
    DECLARE @MovementNo NVARCHAR(30), @MovementStatus TINYINT, @ContainerCount INT;
    SELECT @MovementNo = MovementNo, @MovementStatus = Status FROM logistics.Movements WHERE Id = @Id;
    SET @ContainerCount = (SELECT COUNT(*) FROM logistics.MovementContainers WHERE MovementId = @Id);

    SELECT m.Id, m.DocumentTypeId, m.MovementNo, m.MovementTypeId, mt.TypeCode, mt.TypeName, mt.Stage,
           m.FromPlaceId, fp.PortCode AS FromCode, fp.PortName AS FromName, fp.CountryCode AS FromCountry, fp.Kind AS FromKind,
           m.ToPlaceId, tp.PortCode AS ToCode, tp.PortName AS ToName, tp.CountryCode AS ToCountry, tp.Kind AS ToKind,
           m.PlannedDate, m.StartDate, m.Eta, m.EndDate, m.Status, m.CancelReason,
           m.CarrierPartyId, cp.PartyName AS CarrierName, m.VehicleOrVessel, m.VoyageNo, m.Reference, m.Notes,
           m.StartedAtUtc, su.FullName AS StartedByName, m.CompletedAtUtc, ku.FullName AS CompletedByName,
           m.CancelledAtUtc, xu.FullName AS CancelledByName,
           m.CreatedAtUtc, m.CreatedBy, cu.FullName AS CreatedByName, m.UpdatedAtUtc, m.UpdatedBy, uu.FullName AS UpdatedByName,
           m.RowVersion,
           -- (79) the GRN type's switch: does completing a Delivery draft the goods receipts (the Complete dialog says)
           GoodsReceiptsAutomatic = CAST(ISNULL((SELECT dt.AutoCreateOnDelivery FROM inventory.DocumentTypes dt WHERE dt.Code = N'GRN'), 1) AS BIT),
           -- (80) a planned movement: why it cannot start yet (NULL = it can) and its earliest start date; a movement in
           -- progress: the earliest start date its edited start date may take (usp_Movement_Save, 70018)
           StartBlockedReason = sb.Reason, sb.StartNotBefore, sb.StartNotBeforeMovementNo, sb.StartNotBeforePlaceName,
           -- (82) the movement it was split off (usp_Movement_SplitContainers): "Split from MOV-..."
           m.SplitFromMovementId, SplitFromMovementNo = sf.MovementNo,
           -- (82) cancelling it undoes the split: the movement its containers go back to, as the Cancel dialog says it
           SplitUndoMovementId = ut.MovementId, SplitUndoMovementNo = ut.MovementNo, SplitUndoStatus = ut.Status,
           SplitUndoEndDate = ut.EndDate, SplitUndoToName = ut.ToName, SplitUndoStage = ut.Stage,
           -- (83) can it be cancelled now and, when it cannot, the first refusal of its Cancel in the Cancel's own words
           -- (fn_Movement_CancelBlock): the page disables its "Cancel..." with it
           CanCancel = CAST(CASE WHEN cb.Reason IS NULL THEN 1 ELSE 0 END AS BIT), CancelBlockedReason = cb.Reason
    FROM logistics.Movements m
    INNER JOIN masterdata.MovementTypes mt ON mt.Id = m.MovementTypeId
    INNER JOIN masterdata.Ports fp         ON fp.Id = m.FromPlaceId
    INNER JOIN masterdata.Ports tp         ON tp.Id = m.ToPlaceId
    LEFT  JOIN masterdata.Parties cp       ON cp.Id = m.CarrierPartyId
    LEFT  JOIN security.Users su ON su.Id = m.StartedBy
    LEFT  JOIN security.Users ku ON ku.Id = m.CompletedBy
    LEFT  JOIN security.Users xu ON xu.Id = m.CancelledBy
    LEFT  JOIN security.Users cu ON cu.Id = m.CreatedBy
    LEFT  JOIN security.Users uu ON uu.Id = m.UpdatedBy
    OUTER APPLY logistics.fn_Movement_StartBlock(m.Id) sb   -- (80)
    LEFT  JOIN logistics.Movements sf ON sf.Id = m.SplitFromMovementId                  -- (82)
    OUTER APPLY logistics.fn_Movement_SplitUndoTarget(m.Id) ut                          -- (82)
    OUTER APPLY logistics.fn_Movement_CancelBlock(m.Id) cb                              -- (83)
    WHERE m.Id = @Id;

    SELECT c.Id AS ContainerId, c.ContainerRef, c.ContainerNo, ct.TypeCode AS ContainerTypeCode, c.Status AS ContainerStatus,
           c.CurrentLocation, c.TotalAllocatedBase, c.TotalOilQty,
           ItemSummary = CASE WHEN ln.ItemCount = 1 THEN ln.FirstItem WHEN ln.ItemCount > 1 THEN N'Mixed - ' + CAST(ln.ItemCount AS NVARCHAR(10)) + N' items' END,
           SupplierName = ln.FirstSupplier,
           ChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id AND ch.MovementId = @Id AND ch.Status = 2),
           DraftChargesBase = (SELECT SUM(ch.AmountBase) FROM logistics.ContainerCharges ch WHERE ch.ContainerId = c.Id AND ch.MovementId = @Id AND ch.Status = 1),
           AttachmentCount = (SELECT COUNT(*) FROM logistics.ContainerAttachments a WHERE a.ContainerId = c.Id AND a.MovementId = @Id),
           c.RowVersion AS ContainerRowVersion,
           -- (65) the container's open goods receipt (a draft or the posted one) and the warehouse its draft would take:
           -- the Complete dialog of a Delivery says what will be created ("draft goods receipt into LUB-WH", "warehouse to
           -- choose", "already has GRN-..."). WarehouseInBranch = the container's warehouse is active, of its branch and
           -- (72) at the bottom of the tree (script 70): the rule of usp_GoodsReceipt_CreateForContainer. AutoDraftOfThisMovement = the receipt is a draft made by
           -- this movement's completion: cancelling the movement deletes it (usp_Movement_SetStatus); the Cancel dialog
           -- names those edited since (GoodsReceiptUpdatedAtUtc / ByName, NULL when never edited).
           GoodsReceiptId = gr.GoodsReceiptId, GoodsReceiptNumber = gr.GoodsReceiptNumber, GoodsReceiptStatus = gr.GoodsReceiptStatus,
           WarehouseCode = w.WarehouseCode,
           WarehouseInBranch = CAST(CASE WHEN w.IsActive = 1 AND w.BranchId = c.BranchId AND masterdata.fn_Warehouse_IsLeaf(w.Id) = 1
                                         THEN 1 ELSE 0 END AS BIT),
           -- (72) why it will not be taken, NULL when it will be (or the container has none: "warehouse to choose")
           WarehouseNote = CAST(CASE WHEN w.Id IS NULL THEN NULL
                                     WHEN w.IsActive = 0 THEN w.WarehouseCode + N', the container''s, is inactive'
                                     WHEN w.BranchId <> c.BranchId THEN w.WarehouseCode + N', the container''s, is not of the container''s branch'
                                     WHEN masterdata.fn_Warehouse_IsLeaf(w.Id) = 0 THEN w.WarehouseCode + N', the container''s, has warehouses under it'
                                END AS NVARCHAR(200)),
           AutoDraftOfThisMovement = CAST(CASE WHEN g.Status = 1 AND g.IsAuto = 1 AND g.MovementId = @Id THEN 1 ELSE 0 END AS BIT),
           GoodsReceiptUpdatedAtUtc = g.UpdatedAtUtc, GoodsReceiptUpdatedByName = gu.FullName,
           -- (82) "Only some containers arrived": can it be split off this movement in progress, and why not
           CanSplitOff = CAST(CASE WHEN sp.Reason IS NULL THEN 1 ELSE 0 END AS BIT), SplitOffBlockedReason = sp.Reason
    FROM logistics.MovementContainers mc
    INNER JOIN logistics.Containers c       ON c.Id = mc.ContainerId
    INNER JOIN masterdata.ContainerTypes ct ON ct.Id = c.ContainerTypeId
    CROSS APPLY logistics.fn_Container_ReceivedBy(c.Id) gr
    LEFT  JOIN purchase.GoodsReceipts g     ON g.Id = gr.GoodsReceiptId
    LEFT  JOIN security.Users gu            ON gu.Id = g.UpdatedBy
    LEFT  JOIN masterdata.Warehouses w      ON w.Id = c.WarehouseId
    OUTER APPLY (SELECT ItemCount = COUNT(DISTINCT cl.ItemId), FirstItem = MIN(i.ItemName), FirstSupplier = MIN(sp.PartyName)
                 FROM logistics.ContainerLines cl
                 INNER JOIN inventory.Items i ON i.Id = cl.ItemId
                 INNER JOIN purchase.PurchaseDocuments d ON d.Id = cl.PurchaseOrderId
                 INNER JOIN masterdata.Parties sp ON sp.Id = d.SupplierId
                 WHERE cl.ContainerId = c.Id) ln
    CROSS APPLY logistics.fn_Movement_SplitBlock(@Id, @MovementNo, @MovementStatus, @ContainerCount, c.Id, c.ContainerRef) sp  -- (82)
    WHERE mc.MovementId = @Id
    ORDER BY c.ContainerRef;

    SELECT ch.Id, ch.ContainerId, c.ContainerRef, ch.GroupId, ch.ChargeTypeId, t.ChargeCode, t.ChargeName, ch.Description,
           pp.PartyName AS ProviderName, ch.Reference, ch.ChargeDate, cur.CurrencyCode, ch.Amount, ch.AmountBase,
           ch.AllocationMethod, ch.IncludeInLandedCost, ch.Status, ch.RowVersion
    FROM logistics.ContainerCharges ch
    INNER JOIN logistics.Containers c    ON c.Id = ch.ContainerId
    INNER JOIN purchase.ChargeTypes t    ON t.Id = ch.ChargeTypeId
    INNER JOIN masterdata.Currencies cur ON cur.Id = ch.CurrencyId
    LEFT  JOIN masterdata.Parties pp     ON pp.Id = ch.ProviderPartyId
    WHERE ch.MovementId = @Id
    ORDER BY ch.ChargeDate, c.ContainerRef, ch.Id;

    SELECT a.Id, a.ContainerId, c.ContainerRef, a.ChargeId, a.AttachmentTypeId, at.Category, at.SubType,
           a.FileId, f.FileName, f.ContentType, f.SizeBytes, a.Note, a.DocumentDate, a.GroupId,
           a.CreatedAtUtc, u.FullName AS CreatedByName
    FROM logistics.ContainerAttachments a
    INNER JOIN logistics.Containers c        ON c.Id = a.ContainerId
    INNER JOIN logistics.Files f             ON f.Id = a.FileId
    LEFT  JOIN masterdata.AttachmentTypes at ON at.Id = a.AttachmentTypeId
    LEFT  JOIN security.Users u              ON u.Id = a.CreatedBy
    WHERE a.MovementId = @Id
    ORDER BY a.CreatedAtUtc DESC, c.ContainerRef;

    -- 5: (82) its history beyond its own stamps (logistics.MovementAudit): a split, on the original and on the copy
    SELECT a.Id, a.Action, a.Details, a.UserId, u.FullName AS UserName, a.AtUtc
    FROM logistics.MovementAudit a
    LEFT JOIN security.Users u ON u.Id = a.UserId
    WHERE a.MovementId = @Id
    ORDER BY a.AtUtc DESC, a.Id DESC;
END

GO

/* ================================================================== 4. Check */

-- The latest movements: can each be cancelled now and, when it cannot, the refusal its Cancel gives (the same words).
SELECT TOP (20) Movement = m.MovementNo, m.Status, CanCancel = CAST(CASE WHEN b.Reason IS NULL THEN 1 ELSE 0 END AS BIT),
       b.ErrorNumber, CancelBlockedReason = b.Reason
FROM logistics.Movements m
CROSS APPLY logistics.fn_Movement_CancelBlock(m.Id) b
ORDER BY m.Id DESC;

PRINT 'Script 83 applied: a movement that cannot be cancelled says why before the click - the refusals of its Cancel in one place (logistics.fn_Movement_CancelBlock), read by the Cancel itself and by the movement page.';
GO
